defmodule Opsmaru.TestSupport.NativeImageBackend do
  @moduledoc """
  Database-free image copy oracle, never a workload backend.

  Each side answers the native image routes the pinned v7.0.1 client and
  server use for a copy, and checks the image secrets as incusd does. The
  server-to-server legs run the unchanged pinned client calls of incusd's
  pull download and export push through the gateway driver.
  """
  alias Opsmaru.Incus.Connection
  alias Opsmaru.TestSupport.{HTTPFixture, NativeMigrationBackend}

  @content "opsmaru gateway image copy fixture\n"
  @pull_secret "pull-secret"
  @push_secret "push-secret"

  def extensions, do: ~w(images_push_relay)
  def content, do: @content
  def fingerprint, do: Base.encode16(:crypto.hash(:sha256, @content), case: :lower)

  def model,
    do: %{
      "fingerprint" => fingerprint(),
      "filename" => "fixture.tar.xz",
      "size" => byte_size(@content),
      "type" => "container",
      "architecture" => "aarch64",
      "public" => false,
      "properties" => %{},
      "aliases" => [],
      "profiles" => [],
      "auto_update" => false
    }

  def start(context, name) do
    log = ExUnit.Callbacks.start_supervised!({Agent, fn -> [] end}, id: make_ref())
    state = %{root: context.root, name: name, log: log}

    fixture =
      ExUnit.Callbacks.start_supervised!(
        {HTTPFixture,
         [
           transport: :gen_tcp,
           path: Path.join(context.root, "img-#{name}-#{System.unique_integer([:positive])}"),
           handler: &respond(state, &1, URI.parse(&1.target))
         ]},
        id: make_ref()
      )

    endpoint = HTTPFixture.endpoint(fixture)

    %{
      fixture: fixture,
      connection: Connection.unix!(endpoint.socket, owner: :fixture),
      name: name,
      log: log
    }
  end

  def events(side), do: Agent.get(side.log, &Enum.reverse/1)
  def requests(side), do: HTTPFixture.requests(side.fixture)

  defp respond(side, request, %URI{path: path, query: query}) do
    query = URI.decode_query(query || "")
    image = "/1.0/images/" <> fingerprint()

    case {request.method, path} do
      {"GET", "/1.0"} ->
        discovery(side)

      {"POST", "/1.0/images/" <> _ = secret_path} when secret_path == image <> "/secret" ->
        record(side, {:secret_created, side.name})
        done(side, "secret", nil)
        accepted("secret", %{secret: @pull_secret})

      {"GET", ^image} ->
        with_secret(query, @pull_secret, fn -> sync(model()) end)

      {"GET", "/1.0/images/" <> _ = export} when export == image <> "/export" ->
        with_secret(query, @pull_secret, fn ->
          record(side, {:exported, side.name, query["secret"]})

          %{
            raw: [
              "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\n",
              "Content-Disposition: attachment; filename=fixture.tar.xz\r\n",
              "Content-Length: #{byte_size(@content)}\r\nConnection: close\r\n\r\n",
              @content
            ]
          }
        end)

      {"POST", "/1.0/images/" <> _ = export} when export == image <> "/export" ->
        push_out(side, Jason.decode!(request.body))
        accepted("export", %{})

      {"POST", "/1.0/images"} ->
        create(side, request)

      {method, "/1.0/operations/" <> rest} ->
        operation_route(side, method, rest, query)

      _ ->
        %{status: 404, body: %{type: "error", error: "not found", error_code: 404}}
    end
  end

  defp operation_route(side, "DELETE", id, _query) do
    record(side, {:cancelled, side.name, id})
    sync(%{})
  end

  defp operation_route(side, "GET", rest, query) do
    id = rest |> String.split("/") |> hd()

    if String.ends_with?(rest, "/wait") and query["secret"] != nil,
      do: with_secret(query, @push_secret, fn -> operation(side, id) end),
      else: operation(side, id)
  end

  defp create(side, request) do
    case request.headers["content-type"] do
      "application/json" ->
        body = Jason.decode!(request.body)

        case get_in(body, ["source", "mode"]) do
          "pull" ->
            pull_in(side, body["source"])
            accepted("copy", %{})

          "push" ->
            record(side, {:push_token, side.name, body})
            accepted("token", %{secret: @push_secret})
        end

      _ ->
        upload(side, request)
    end
  end

  # incusd imagesPost: an upload carrying a secret must match a pending push
  # token for the same fingerprint; one without a secret is the trusted caller.
  defp upload(side, request) do
    secret = request.headers["x-incus-secret"]
    fingerprint = request.headers["x-incus-fingerprint"]

    cond do
      secret == nil ->
        record(side, {:uploaded, side.name, :caller, request.body})
        done(side, "upload", nil)
        accepted("upload", %{})

      secret == @push_secret and fingerprint == fingerprint() ->
        record(side, {:uploaded, side.name, :peer, request.body})
        done(side, "pushed", nil)
        accepted("pushed", %{secret: @push_secret})

      true ->
        forbidden()
    end
  end

  defp pull_in(side, source) do
    spawn(fn ->
      result =
        NativeMigrationBackend.run(side.root, %{
          Action: "imagepull",
          Server: source["server"],
          Certificate: source["certificate"],
          Fingerprint: source["fingerprint"],
          Secret: source["secret"],
          Project: source["project"] || "",
          Temp: side.root
        })

      record(side, {:outbound, side.name, :pull, source["server"], result})

      error =
        cond do
          result["error"] -> result["error"]
          result["fingerprint"] != fingerprint() -> "pulled image fingerprint mismatch"
          true -> nil
        end

      done(side, "copy", error)
    end)
  end

  defp push_out(side, body) do
    record(side, {:export_request, side.name, body})

    spawn(fn ->
      result =
        NativeMigrationBackend.run(side.root, %{
          Action: "imagepush",
          Server: body["target"],
          Certificate: body["certificate"],
          Fingerprint: fingerprint(),
          Secret: body["secret"],
          Project: body["project"] || "",
          Content: @content,
          Temp: side.root
        })

      record(side, {:outbound, side.name, :push, body["target"], result})
      done(side, "export", result["error"])
    end)
  end

  defp operation(side, id) do
    error = await(side, id, System.monotonic_time(:millisecond) + 8_000)

    sync(%{
      id: id,
      class: "task",
      status: if(error, do: "Failure", else: "Success"),
      status_code: if(error, do: 400, else: 200),
      err: error || "",
      may_cancel: false,
      metadata: if(id == "pushed", do: %{secret: @push_secret}, else: %{})
    })
  end

  defp await(side, id, deadline) do
    found =
      Enum.find_value(events(side), fn
        {:done, ^id, error} -> {:done, error}
        _ -> nil
      end)

    cond do
      found ->
        elem(found, 1)

      System.monotonic_time(:millisecond) >= deadline ->
        "image fixture operation #{id} did not finish"

      true ->
        Process.sleep(10)
        await(side, id, deadline)
    end
  end

  defp with_secret(query, expected, fun) do
    case query["secret"] do
      nil -> fun.()
      ^expected -> fun.()
      _ -> forbidden()
    end
  end

  defp discovery(side),
    do:
      sync(%{
        api_version: "1.0",
        auth: "trusted",
        public: false,
        api_extensions: extensions(),
        environment: %{
          server_name: side.name,
          server: "incus",
          server_version: "7.0.1",
          addresses: ["127.0.0.1:9", "10.0.2.15:8443"],
          certificate: "guest certificate"
        }
      })

  defp done(side, id, error), do: record(side, {:done, id, error})
  defp record(side, event), do: Agent.update(side.log, &[event | &1])

  defp forbidden,
    do: %{status: 403, body: %{type: "error", error: "not authorized", error_code: 403}}

  defp sync(metadata),
    do: %{
      status: 200,
      body: %{type: "sync", status: "Success", status_code: 200, metadata: metadata}
    }

  defp accepted(id, metadata),
    do: %{
      status: 202,
      body: %{
        type: "async",
        status_code: 100,
        operation: "/1.0/operations/" <> id,
        metadata: %{
          id: id,
          class: "task",
          status: "Running",
          status_code: 103,
          may_cancel: true,
          metadata: metadata
        }
      }
    }
end
