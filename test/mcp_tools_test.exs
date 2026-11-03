defmodule Opsmaru.Incus.MCPToolsTest do
  use ExUnit.Case, async: false
  alias Opsmaru.Incus.MCP.Tools
  alias Opsmaru.Incus.Operations
  alias Opsmaru.TestSupport.{MCPHost, OperationsFixture}
  alias TamaMCP.Transport.StreamableHTTP.Plug, as: MCPPlug
  import OperationsFixture, only: [sync: 1]

  @version "2026-07-28"
  @server_meta %{
    "io.modelcontextprotocol/serverInfo" => %{"name" => "fixture-host", "version" => "1.0.0"}
  }
  @host_tool %{
    "name" => "host_status",
    "title" => "Host status",
    "description" => "Report the fixture host status.",
    "inputSchema" => %{"type" => "object", "properties" => %{}, "additionalProperties" => false},
    "outputSchema" => %{
      "type" => "object",
      "properties" => %{"status" => %{"type" => "string"}},
      "required" => ["status"],
      "additionalProperties" => false
    }
  }

  setup do
    root = OperationsFixture.root()
    on_exit(fn -> File.rm_rf!(root) end)

    fixture =
      OperationsFixture.start(root, :gen_tcp, fn request ->
        case request.target do
          "/1.0/instances?recursion=1" -> sync([%{"name" => "vm1", "type" => "virtual-machine"}])
          _ -> :next
        end
      end)

    plug =
      MCPPlug.init(
        server: MCPHost.Server,
        authorization: MCPHost.Authorization,
        authorization_options: [binding: {fixture.connection, fixture.context}],
        cache: MCPHost.Cache
      )

    %{fixture: fixture, request: &request(plug, &1)}
  end

  defp request(plug, %{"headers" => headers, "body" => body}) do
    conn =
      Enum.reduce(headers, Plug.Test.conn(:post, "/", Jason.encode!(body)), fn [name, value],
                                                                               conn ->
        Plug.Conn.put_req_header(conn, name, value)
      end)
      |> MCPPlug.call(plug)

    %{status: conn.status, headers: conn.resp_headers, body: Jason.decode!(conn.resp_body)}
  end

  defp wire(token, id, method, params, name \\ nil) do
    headers =
      [
        ["mcp-protocol-version", @version],
        ["mcp-method", method],
        ["content-type", "application/json"],
        ["accept", "application/json, text/event-stream"],
        ["x-test-token", token]
      ] ++ if(name, do: [["mcp-name", name]], else: [])

    meta = %{
      "io.modelcontextprotocol/protocolVersion" => @version,
      "io.modelcontextprotocol/clientCapabilities" => %{}
    }

    %{
      "headers" => headers,
      "body" => %{
        "jsonrpc" => "2.0",
        "id" => id,
        "method" => method,
        "params" => Map.put(params, "_meta", meta)
      }
    }
  end

  defp fixture(name, request, request_schema, response_schema, status, body, headers \\ %{}) do
    %{
      "name" => name,
      "requestSchema" => request_schema,
      "requestValid" => true,
      "responseSchema" => response_schema,
      "request" => request,
      "expected" => %{
        "status" => status,
        "headers" => Map.put(headers, "content-type", "application/json; charset=utf-8"),
        "body" => body
      }
    }
  end

  defp listed(descriptors) do
    shared =
      for descriptor <- descriptors,
          do: %{
            "name" => descriptor.name,
            "title" => descriptor.title,
            "description" => descriptor.description,
            "inputSchema" => descriptor.input_schema,
            "outputSchema" => Operations.output_schema(descriptor)
          }

    Enum.sort_by([@host_tool | shared], & &1["name"])
  end

  defp call(token, id, name, arguments),
    do: wire(token, id, "tools/call", %{"name" => name, "arguments" => arguments}, name)

  defp result(id, structured, error? \\ false),
    do: %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{
        "resultType" => "complete",
        "content" => [%{"type" => "text", "text" => Jason.encode!(structured)}],
        "structuredContent" => structured,
        "isError" => error?,
        "_meta" => @server_meta
      }
    }

  test "the composed host passes TamaMCP conformance for shared and host tools", %{
    fixture: fixture,
    request: request
  } do
    read = Enum.filter(Operations.all(), &(&1.scope == "incus.read"))
    {:ok, list} = Operations.fetch("incus_instance_list")
    {:ok, delete} = Operations.fetch("incus_instance_delete")

    fixtures = [
      fixture(
        "discovery advertises tools and no tasks",
        wire("all", "d1", "server/discover", %{}),
        "discover_request",
        "discover_response",
        200,
        %{
          "jsonrpc" => "2.0",
          "id" => "d1",
          "result" => %{
            "resultType" => "complete",
            "supportedVersions" => [@version],
            "capabilities" => %{"tools" => %{}},
            "ttlMs" => 0,
            "cacheScope" => "private",
            "_meta" => @server_meta
          }
        }
      ),
      fixture(
        "full catalogue under all scopes",
        wire("all", "l1", "tools/list", %{}),
        "list_tools_request",
        "list_tools_response",
        200,
        %{
          "jsonrpc" => "2.0",
          "id" => "l1",
          "result" => %{
            "resultType" => "complete",
            "tools" => listed(Operations.all()),
            "ttlMs" => 0,
            "cacheScope" => "private",
            "_meta" => @server_meta
          }
        }
      ),
      fixture(
        "scope-filtered catalogue for a read-only caller",
        wire("read", "l2", "tools/list", %{}),
        "list_tools_request",
        "list_tools_response",
        200,
        %{
          "jsonrpc" => "2.0",
          "id" => "l2",
          "result" => %{
            "resultType" => "complete",
            "tools" => listed(read),
            "ttlMs" => 0,
            "cacheScope" => "private",
            "_meta" => @server_meta
          }
        }
      ),
      fixture(
        "shared tool call returns native data",
        call("read", "c1", list.name, %{"limit" => 5}),
        "call_tool_request",
        "call_tool_response",
        200,
        result("c1", %{
          "items" => [%{"name" => "vm1", "type" => "virtual-machine"}],
          "count" => 1,
          "truncated" => false
        })
      ),
      fixture(
        "host tool on the same endpoint",
        call("read", "c2", "host_status", %{}),
        "call_tool_request",
        "call_tool_response",
        200,
        %{
          "jsonrpc" => "2.0",
          "id" => "c2",
          "result" => %{
            "resultType" => "complete",
            "content" => [],
            "structuredContent" => %{"status" => "ok"},
            "isError" => false,
            "_meta" => @server_meta
          }
        }
      ),
      fixture(
        "read-only caller is denied deletion by scope",
        call("read", "c3", delete.name, %{"name" => "vm1", "confirm" => "vm1"}),
        "call_tool_request",
        "error_response",
        403,
        %{
          "jsonrpc" => "2.0",
          "id" => "c3",
          "error" => %{
            "code" => -32_600,
            "message" => "Insufficient scope for tool incus_instance_delete",
            "data" => %{"reason" => "scope_denied", "requiredScopes" => ["incus.delete"]}
          }
        },
        %{"www-authenticate" => "Bearer error=\"insufficient_scope\", scope=\"incus.delete\""}
      ),
      fixture(
        "missing confirmation fails input validation",
        call("all", "c4", delete.name, %{"name" => "vm1"}),
        "call_tool_request",
        "error_response",
        400,
        %{
          "jsonrpc" => "2.0",
          "id" => "c4",
          "error" => %{
            "code" => -32_602,
            "message" =>
              "Invalid arguments for tool incus_instance_delete: Missing required properties: confirm"
          }
        }
      ),
      fixture(
        "mismatched confirmation is a tool error",
        call("all", "c5", delete.name, %{"name" => "vm1", "confirm" => "yes"}),
        "call_tool_request",
        "call_tool_response",
        200,
        result(
          "c5",
          %{
            "error" => %{
              "kind" => "confirmation_required",
              "message" => "set confirm to \"vm1\" to confirm this destructive operation"
            }
          },
          true
        )
      ),
      fixture(
        "a decision without the host assign is denied by the binding",
        call("nohost", "c6", list.name, %{}),
        "call_tool_request",
        "call_tool_response",
        200,
        result(
          "c6",
          %{
            "error" => %{
              "kind" => "host_binding_failed",
              "message" => "the host supplied no backend for this caller"
            }
          },
          true
        )
      )
    ]

    case TamaMCP.Conformance.run(request, MCPHost.Cache, fixtures) do
      :ok -> :ok
      {:error, errors} -> flunk(Enum.join(errors, "\n"))
    end

    # Only the two successful shared calls reached the backend, each after discovery.
    assert Enum.map(OperationsFixture.requests(fixture), & &1.target) == [
             "/1.0",
             "/1.0/instances?recursion=1"
           ]
  end

  test "every tool module mirrors its descriptor and never creates tasks" do
    assert length(Tools.all()) == length(Operations.all())

    for {{name, module}, descriptor} <- Enum.zip(Tools.all(), Operations.all()) do
      assert name == descriptor.name and module.canonical_name() == name
      assert Tools.module(name) == module
      assert module.scopes() == [descriptor.scope]
      assert module.task_policy() == :disabled
      assert module.input_schema() == descriptor.input_schema
      assert module.output_schema() == Operations.output_schema(descriptor)

      refute function_exported?(module, :start_link, 1) or
               function_exported?(module, :child_spec, 1)
    end

    assert MCPHost.Server.tool_names() ==
             Enum.sort(["host_status" | Enum.map(Tools.all(), &elem(&1, 0))])
  end

  test "a host tool reusing a shared name fails host compilation" do
    source = """
    defmodule Opsmaru.Incus.MCPToolsTest.Duplicate do
      use TamaMCP.Server, name: "dup", version: "1.0.0"
      require Opsmaru.Incus.MCP.Tools
      Opsmaru.Incus.MCP.Tools.register()
      tool Opsmaru.TestSupport.MCPHost.Status, name: "incus_instance_list"
    end
    """

    assert_raise CompileError, ~r/duplicate tool name.*incus_instance_list/, fn ->
      Code.compile_string(source)
    end
  end

  test "tool calls run in the request and leave no process behind", %{request: request} do
    before = MapSet.new(Process.list())
    assert %{status: 200} = request.(call("read", "p1", "incus_instance_list", %{}))
    Process.sleep(100)

    assert Enum.filter(Process.list(), &(not MapSet.member?(before, &1) and Process.alive?(&1))) ==
             []
  end
end
