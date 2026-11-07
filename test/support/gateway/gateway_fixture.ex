defmodule Opsmaru.TestSupport.GatewayHost do
  @moduledoc """
  Fixture-only gateway host policy. `host_config` is a map with `:observer`,
  `:ready` (boolean or zero-arity function) and `:authorize` (one-arity
  function). Every authorization request is reported to the observer.
  """
  @behaviour Opsmaru.Incus.Gateway.Host

  @impl true
  def ready?(%{ready: ready}) when is_function(ready, 0), do: ready.()
  def ready?(%{ready: ready}), do: ready

  @impl true
  def authorize(request, config) do
    send(config.observer, {:host_authorize, request})
    config.authorize.(request)
  end

  @impl true
  def valid?(request, grant, config), do: config.valid.(request, grant)

  @impl true
  def identity(_request, config) do
    case config.identity do
      callback when is_function(callback, 0) -> callback.()
      identity -> {:ok, identity}
    end
  end

  @impl true
  def certificates(action, request, grant, input, config),
    do: config.certificates.(action, request, grant, input)

  @doc "Default policy: one bearer token, projects nil (native default) or \"allowed\"."
  def default_authorize(request) do
    cond do
      request.authorization == nil -> {:error, :unauthenticated}
      request.authorization != "Bearer fixture-token" -> {:error, :forbidden}
      request.project not in [nil, "allowed"] -> {:error, :forbidden}
      request.all_projects -> {:error, :forbidden}
      true -> {:ok, :fixture_grant}
    end
  end
end

defmodule Opsmaru.TestSupport.GatewayServer do
  @moduledoc """
  Host-owned fixture endpoint: a Plug.Router on Plug.Cowboy that mounts the
  gateway at `/` and `/1.0` beside host `/runtime` and `/mcp` routes. The
  gateway is resolved per request, as a host would resolve runtime
  configuration.

  Each test owns its gateway and listeners, so gateway tests run concurrently:
  `put_gateway/1` binds the gateway to the calling test process, the listeners it
  starts are bound to it by local port, and the router records which listener
  accepted a request before the gateway plug resolves it. The table lives in
  the test runner (`init/0` from `test_helper.exs`), not in any test process.
  """

  alias Opsmaru.Incus.Gateway

  @table __MODULE__

  @doc "Create the fixture's table; call once from `test_helper.exs`."
  def init do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    :ok
  end

  @doc """
  The gateway for this request's listener, or in a test process its own.
  `nil` when none is bound, which the gateway plug serves as unconfigured.
  """
  def gateway do
    port = Process.get(__MODULE__)

    case :ets.lookup(@table, {:port_gateway, port}) do
      [{_, gateway}] -> gateway
      [] -> owner_gateway()
    end
  end

  defp owner_gateway do
    with owner when is_pid(owner) <- owner(),
         [{_, gateway}] <- :ets.lookup(@table, {:gateway, owner}) do
      gateway
    else
      _ -> nil
    end
  end

  def put_gateway(%Gateway{} = gateway) do
    :ets.insert(@table, {{:gateway, self()}, gateway})
    :ok
  end

  @doc "Bind a fixture gateway to one listener, for source/target migration pairs."
  def put_gateway(%Gateway{} = gateway, port) do
    :ets.insert(@table, {{:port_gateway, port}, gateway})
    :ok
  end

  @doc "Forget `owner`'s gateway; `on_exit` callbacks pass the test pid explicitly."
  def clear(owner \\ self()) do
    :ets.delete(@table, {:gateway, owner})
    :ok
  end

  @doc false
  # Called by the router in the request process before any gateway mount.
  def accepted_on(port), do: Process.put(__MODULE__, port)

  defp owner do
    case Process.get(__MODULE__) do
      nil ->
        self()

      port ->
        case :ets.lookup(@table, {:listener, port}) do
          [{_, owner}] -> owner
          [] -> nil
        end
    end
  end

  defp bind(ref) do
    port = :ranch.get_port(ref)
    :ets.insert(@table, {{:listener, port}, self()})
    {ref, port}
  end

  @doc "Start an HTTP listener on 127.0.0.1; returns `{ref, port}`."
  def start_http(opts \\ []) do
    ref = {__MODULE__, make_ref()}

    {:ok, _} =
      Plug.Cowboy.http(Opsmaru.TestSupport.GatewayRouter, [],
        ref: ref,
        ip: {127, 0, 0, 1},
        port: 0,
        protocol_options: Keyword.get(opts, :protocol_options, [])
      )

    bind(ref)
  end

  @doc "Start an HTTPS listener requesting (not requiring) client certificates."
  def start_https(server, client_ca) do
    ref = {__MODULE__, make_ref()}

    {:ok, _} =
      Plug.Cowboy.https(Opsmaru.TestSupport.GatewayRouter, [],
        ref: ref,
        ip: {127, 0, 0, 1},
        port: 0,
        certfile: server.certfile,
        keyfile: server.keyfile,
        cacertfile: client_ca,
        verify: :verify_peer,
        fail_if_no_peer_cert: false,
        versions: [:"tlsv1.3"],
        alpn_preferred_protocols: ["http/1.1"]
      )

    bind(ref)
  end

  def stop(ref) do
    port = :ranch.get_port(ref)
    :ets.delete(@table, {:listener, port})
    :ets.delete(@table, {:port_gateway, port})
    Plug.Cowboy.shutdown(ref)
  end
end

defmodule Opsmaru.TestSupport.GatewayRuntimePlug do
  @moduledoc false
  # A host route with its own JSON body parsing, beside the gateway.
  use Plug.Builder

  plug(Plug.Parsers, parsers: [:json], json_decoder: Jason, pass: ["*/*"])
  plug(:respond)

  def respond(conn, _),
    do: send_resp(conn, 200, Jason.encode!(%{"runtime" => conn.body_params}))
end

defmodule Opsmaru.TestSupport.GatewayParsedPlug do
  @moduledoc false
  # A misconfigured mount: a blanket body parser in front of the gateway.
  use Plug.Builder

  plug(Plug.Parsers, parsers: [:json], json_decoder: Jason, pass: ["*/*"])
  plug(Opsmaru.Incus.Gateway.Plug, gateway: {Opsmaru.TestSupport.GatewayServer, :gateway, []})
end

defmodule Opsmaru.TestSupport.GatewayRouter do
  @moduledoc false
  use Plug.Router

  alias Opsmaru.TestSupport.GatewayServer

  @gateway [gateway: {GatewayServer, :gateway, []}]

  plug(:accepted_on)
  plug(:match)
  plug(:dispatch)

  # The listener's local port, not the Host header: it names the owning test.
  defp accepted_on(%Plug.Conn{adapter: {_, req}} = conn, _) do
    {_, port} = :cowboy_req.sock(req)
    GatewayServer.accepted_on(port)
    conn
  end

  get("/", to: Opsmaru.Incus.Gateway.Plug, init_opts: @gateway)
  forward("/1.0", to: Opsmaru.Incus.Gateway.Plug, init_opts: @gateway)
  forward("/runtime", to: Opsmaru.TestSupport.GatewayRuntimePlug)
  forward("/parsed", to: Opsmaru.TestSupport.GatewayParsedPlug)

  post "/mcp" do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    send_resp(conn, 200, "mcp:" <> body)
  end

  match _ do
    send_resp(conn, 404, "host route not found")
  end
end
