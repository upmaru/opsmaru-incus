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

  @doc "Default policy: one bearer token, projects nil (native default) or \"allowed\"."
  def default_authorize(request) do
    cond do
      request.authorization != "Bearer fixture-token" -> {:error, :unauthenticated}
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
  gateway is resolved per request from `:persistent_term`, as a host would
  resolve runtime configuration.
  """

  alias Opsmaru.Incus.Gateway

  @key {__MODULE__, :gateway}

  def gateway, do: :persistent_term.get(@key, nil)
  def put_gateway(%Gateway{} = gateway), do: :persistent_term.put(@key, gateway)
  def clear, do: :persistent_term.erase(@key)

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

    {ref, :ranch.get_port(ref)}
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

    {ref, :ranch.get_port(ref)}
  end

  def stop(ref), do: Plug.Cowboy.shutdown(ref)
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

  @gateway [gateway: {Opsmaru.TestSupport.GatewayServer, :gateway, []}]

  plug(:match)
  plug(:dispatch)

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
