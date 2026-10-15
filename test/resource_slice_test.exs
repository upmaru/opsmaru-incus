defmodule Opsmaru.Incus.ResourceSliceTest do
  use ExUnit.Case, async: false
  alias Opsmaru.Incus
  alias Opsmaru.Incus.{Connection, Context, Error, Model, Server}
  alias Opsmaru.TestSupport.{HTTPFixture, WireComparison}
  @catalogue Jason.decode!(File.read!("priv/incus/methods.json"))["methods"]
  @definitions Enum.reject(@catalogue, &(&1["reference_kind"] == "rest"))
  @driver Path.expand("../.integration/incus-typed-driver", __DIR__)

  setup_all do
    {out, status} =
      System.cmd("mise", ["exec", "--", "go", "build", "-o", @driver, "."],
        cd: Path.expand("reference", __DIR__),
        env: [{"GOTOOLCHAIN", "local"}],
        stderr_to_stdout: true
      )

    assert status == 0, out
    :ok
  end

  setup do
    root = Path.join(System.tmp_dir!(), "op-resource-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)

    %{
      root: root,
      context: Context.new!(owner: :fixture, identity: :verified, ready?: fn -> true end)
    }
  end

  for metadata <- [%{"id" => "accepted", "status_code" => "wrong"}, ["wrong"], nil] do
    test "accepted mutation with malformed metadata #{inspect(metadata)} remains uncertain", %{
      root: root,
      context: context
    } do
      metadata = unquote(Macro.escape(metadata))

      fixture =
        start_supervised!(
          {HTTPFixture,
           transport: :gen_tcp,
           path: Path.join(root, "bad-accepted"),
           handler: fn _ ->
             %{
               status: 202,
               body: %{
                 "type" => "async",
                 "status_code" => 100,
                 "operation" => "/1.0/operations/accepted",
                 "metadata" => metadata
               }
             }
           end}
        )

      connection = Connection.unix!(HTTPFixture.endpoint(fixture).socket, owner: :fixture)

      client = %Incus{
        connection: connection,
        context: context,
        server: %Server{api_extensions: []}
      }

      assert {:error,
              %Error{kind: :uncertain, operation: "/1.0/operations/accepted", response: response}} =
               Incus.call(client, "CreateInstance", %{},
                 body: %{"name" => "fixture", "source" => %{"type" => "none"}}
               )

      assert response.type == "async"
      assert response.operation == "/1.0/operations/accepted"
      assert response.metadata == metadata
      assert response.connection == connection
      assert response.identity == context.identity
      assert [%{method: "POST"}] = HTTPFixture.requests(fixture)
    end
  end

  test "successful synchronous mutation with invalid typed metadata is uncertain, not rejected",
       %{root: root, context: context} do
    fixture =
      start_supervised!(
        {HTTPFixture,
         transport: :gen_tcp,
         path: Path.join(root, "bad-sync-mutation"),
         handler: fn _ ->
           %{
             status: 200,
             body: %{"type" => "sync", "status_code" => 200, "metadata" => %{"name" => 42}}
           }
         end}
      )

    connection = Connection.unix!(HTTPFixture.endpoint(fixture).socket, owner: :fixture)

    client = %Incus{
      connection: connection,
      context: context,
      server: %Server{api_extensions: ["storage_buckets"]}
    }

    assert {:error, %Error{kind: :uncertain, response: response}} =
             Incus.call(
               client,
               "CreateStoragePoolBucketKey",
               %{"poolName" => "pool", "bucketName" => "bucket"},
               body: %{"name" => "fixture", "role" => "admin"}
             )

    assert response.metadata == %{"name" => 42}
    assert response.identity == context.identity
    assert [%{method: "POST"}] = HTTPFixture.requests(fixture)
  end

  for method <- @definitions do
    test "official typed method #{method["name"]} agrees on native request and result", %{
      root: root,
      context: context
    } do
      method = unquote(Macro.escape(method))

      args =
        Map.new(method["params"], fn name ->
          {name,
           case name do
             "force" ->
               true

             "timeout" ->
               1

             "filters" ->
               ["name=x", "ignored", "config.user.note=y"]

             "instance_type" ->
               "virtual-machine"

             "instance_name" ->
               "fixture-name"

             "secret" ->
               "0123456789abcdef0123456789abcdef"

             _ ->
               if(name in Map.get(method, "legal_params", []),
                 do: "fixture-name",
                 else: "fixture/name space"
               )
           end}
        end)

      metadata = metadata(method, args)

      response = %{
        status: if(method["result"] == "operation", do: 202, else: 200),
        headers: %{"ETag" => "\"native-etag\""},
        body: %{
          type: if(method["result"] == "operation", do: "async", else: "sync"),
          operation:
            if(method["result"] == "operation", do: "/1.0/operations/native-id", else: ""),
          status_code: 200,
          metadata: metadata
        }
      }

      oracle = backend(root, response)
      body = if method["body"], do: initial_body(method), else: nil

      values =
        Enum.map(method["params"], &args[&1]) ++
          if(method["body"], do: [body], else: []) ++
          if(method["verb"] in ["PUT", "PATCH"], do: ["\"before\""], else: [])

      values = values ++ Map.get(method, "oracle_trailing", [])

      input = %{
        socket: HTTPFixture.endpoint(oracle).socket,
        action: method["oracle_action"] || method["name"],
        args: values,
        project: "fixture scope",
        target: "member/a"
      }

      file = Path.join(root, "oracle.json")
      File.write!(file, Jason.encode!(input))
      {out, status} = System.cmd(@driver, [file], stderr_to_stdout: true)
      assert status == 0, out
      result = Jason.decode!(out)

      if method["oracle_expected_error"],
        do: assert(result["error"] == method["oracle_expected_error"]),
        else: refute(Map.has_key?(result, "error"), out)

      expected_request = HTTPFixture.requests(oracle) |> List.last() |> WireComparison.request()
      client_backend = backend(root, response)

      connection =
        Connection.unix!(HTTPFixture.endpoint(client_backend).socket,
          owner: :fixture,
          project: "fixture scope",
          member: "member/a"
        )

      {:ok, client} = Incus.connect(connection, context)

      opts =
        if method["body"],
          do: [body: Enum.at(result["normalized_args"], length(method["params"]))],
          else: []

      opts =
        if method["verb"] in ["PUT", "PATCH"],
          do: Keyword.put(opts, :etag, "\"before\""),
          else: opts

      assert {:ok, reply} = Incus.call(client, method["name"], args, opts)

      actual_request =
        HTTPFixture.requests(client_backend) |> List.last() |> WireComparison.request()

      assert WireComparison.compare(expected_request, actual_request) == :ok,
             inspect({expected_request["query"], actual_request["query"]})

      assert reply.etag == "\"native-etag\""

      case method["result"] do
        kind when kind in ["names", "project_names", "project_urls", "strings"] ->
          assert reply.metadata == hd(result["outputs"])

        "model" ->
          assert %Model{type: type, data: ^metadata} = reply.metadata
          assert type == method["model"]

        "grouped_list" ->
          assert Enum.map(reply.metadata, & &1.data) == metadata |> Map.values() |> List.flatten()

        "list" ->
          assert Enum.map(reply.metadata, & &1.data) == metadata

        "operation" ->
          assert reply.operation == "/1.0/operations/native-id"
          assert reply.metadata.data["id"] == "native-id"

        "sync" ->
          assert reply.metadata == nil
      end
    end
  end

  test "every method rejects unavailable extensions before dispatch", %{
    root: root,
    context: context
  } do
    fixture = backend(root, %{status: 200, body: %{type: "sync", metadata: nil}})
    connection = Connection.unix!(HTTPFixture.endpoint(fixture).socket, owner: :fixture)

    client = %Incus{
      connection: connection,
      context: context,
      server: %Opsmaru.Incus.Server{api_extensions: []}
    }

    for method <- @catalogue, method["extension"] do
      assert {:error, %Error{kind: :unsupported_extension}} =
               Incus.call(client, method["name"], %{})
    end

    assert HTTPFixture.requests(fixture) == []
    assert {:error, %Error{kind: :unimplemented_method}} = Incus.call(client, "MissingMethod")
  end

  test "model codec preserves unknown/null fields and rejects known type corruption" do
    data = %{"name" => "native", "config" => nil, "devices" => %{}, "future_field" => %{}}
    assert {:ok, %Model{data: ^data} = model} = Model.decode("Profile", data)
    assert Model.encode(model) == data
    assert {:error, :invalid_model} = Model.decode("Profile", Map.put(data, "config", "wrong"))
    refute inspect(model) =~ "future_field"
  end

  test "native failures retain separate HTTP/native codes and never replay any method", %{
    root: root,
    context: context
  } do
    failure = %{
      status: 412,
      headers: %{"ETag" => "ignored"},
      body: %{type: "error", error_code: 777, error: "native failure", metadata: nil}
    }

    fixture = backend(root, failure)
    connection = Connection.unix!(HTTPFixture.endpoint(fixture).socket, owner: :fixture)
    {:ok, client} = Incus.connect(connection, context)

    for method <- @catalogue do
      args =
        Map.new(method["params"], fn name ->
          {name,
           case name do
             "force" -> true
             "filters" -> []
             "timeout" -> 1
             _ -> "native"
           end}
        end)

      opts = if method["body"], do: [body: initial_body(method)], else: []
      opts = if method["verb"] == "PATCH", do: Keyword.put(opts, :etag, "before"), else: opts

      assert {:error,
              %Error{kind: :native, http_status: 412, error_code: 777, message: "native failure"}} =
               Incus.call(client, method["name"], args, opts)
    end

    assert length(HTTPFixture.requests(fixture)) == 1 + length(@catalogue)
  end

  test "snapshot restore retains acceptance and conditional extensions stop incompatible mutations",
       %{root: root, context: context} do
    fixture =
      backend(root, %{
        status: 202,
        body: %{
          type: "async",
          status_code: 100,
          operation: "/1.0/operations/restore-id",
          metadata: %{id: "restore-id", status_code: 103}
        }
      })

    connection = Connection.unix!(HTTPFixture.endpoint(fixture).socket, owner: :fixture)
    {:ok, client} = Incus.connect(connection, context)

    assert {:ok, accepted} =
             Incus.call(client, "UpdateInstance", %{"name" => "fixture"},
               body: %{"restore" => "snapshot-a"},
               etag: "before"
             )

    assert accepted.operation == "/1.0/operations/restore-id"
    assert accepted.metadata.data["status_code"] == 103
    request = HTTPFixture.requests(fixture) |> List.last()
    assert Jason.decode!(request.body) == %{"restore" => "snapshot-a"}
    assert request.headers["if-match"] == "before"
    before = length(HTTPFixture.requests(fixture))

    for {name, args, body, extension} <- [
          {"UpdateInstance", %{"name" => "fixture"}, %{"disk_only" => true},
           "instance_snapshot_disk_only_restore"},
          {"CreateInstance", %{}, %{"source" => %{"instance_only" => true}},
           "container_only_migration"},
          {"CreateInstanceSnapshot", %{"instance_name" => "fixture"},
           %{"expires_at" => "2026-10-11T00:00:00Z"}, "snapshot_expiry_creation"}
        ] do
      assert {:error, %Error{kind: :unsupported_extension, extension: ^extension}} =
               Incus.call(%{client | server: %{client.server | api_extensions: []}}, name, args,
                 body: body
               )
    end

    assert length(HTTPFixture.requests(fixture)) == before

    assert {:error, %Error{kind: :invalid_body}} =
             Incus.call(client, "RenameInstance", %{"name" => "fixture"},
               body: %{"migration" => true}
             )
  end

  defp backend(root, response) do
    extensions =
      @definitions
      |> Enum.flat_map(fn method ->
        List.wrap(method["extension"]) ++
          Enum.flat_map(method["guards"], &List.wrap(&1["extension"]))
      end)
      |> Enum.uniq()

    start_supervised!(
      {HTTPFixture,
       transport: :gen_tcp,
       path: Path.join(root, "sock-#{System.unique_integer([:positive])}"),
       handler: fn request ->
         if request.method == "GET" and URI.parse(request.target).path == "/1.0" do
           %{
             status: 200,
             body: %{
               type: "sync",
               status_code: 200,
               metadata: %{api_version: "1.0", api_extensions: extensions, environment: %{}}
             }
           }
         else
           response
         end
       end},
      id: make_ref()
    )
  end

  defp metadata(method, args) do
    resolved =
      Enum.reduce(args, method["path"], fn {key, value}, path ->
        if is_binary(value),
          do: String.replace(path, "{" <> key <> "}", URI.encode(value, &URI.char_unreserved?/1)),
          else: path
      end)

    metadata(%{method | "path" => resolved})
  end

  defp metadata(%{"result" => "project_names"}),
    do: [%{"name" => "native", "project" => "native-project"}]

  defp metadata(%{"result" => "strings"}), do: ["native.txt"]

  defp metadata(%{"result" => "project_urls", "path" => path}),
    do: [path <> "/custom/native?project=native-project"]

  defp metadata(%{"model" => "ProjectState"}),
    do: %{"resources" => %{"cpu" => %{"limit" => 4, "usage" => 2}}}

  defp metadata(%{"model" => "InstanceState"}),
    do: %{"status" => "Running", "status_code" => 103, "pid" => 42, "processes" => 1}

  defp metadata(%{"result" => "grouped_list"}),
    do: %{"running" => [%{"id" => "native-id", "status_code" => 103}]}

  defp metadata(%{"result" => "operation"}),
    do: %{"id" => "native-id", "status_code" => 103, "metadata" => nil, "may_cancel" => false}

  defp metadata(%{"result" => "names", "path" => path}), do: [path <> "/fixture%2Fname"]

  defp metadata(%{"result" => "model", "model" => "Access"}),
    do: [%{"identifier" => "native", "role" => "admin"}]

  defp metadata(%{"result" => "model"}), do: %{"name" => "native"}
  defp metadata(%{"result" => "list"}), do: [%{"name" => "native"}]
  defp metadata(_), do: nil

  defp initial_body(%{"name" => "CreateCertificateToken"}),
    do: %{"token" => true, "name" => "native"}

  defp initial_body(%{"name" => "Migrate" <> _}), do: %{"migration" => true, "name" => "native"}

  defp initial_body(_), do: %{"name" => "native", "description" => "fixture"}
end
