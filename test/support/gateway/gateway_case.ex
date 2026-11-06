defmodule Opsmaru.TestSupport.GatewayCase do
  @moduledoc """
  Shared setup for gateway fixtures: an owner-private temporary directory, a
  host-started admission, a host-owned Plug.Cowboy listener mounting the
  gateway, and helpers for a scripted Unix backend.

  Each test's gateway is bound to its own listener (`GatewayServer`), so
  modules using it may run `async: true`. Keep a module serial when its evidence
  is a latency bound (revocation, the lease's admission-loss grace).
  """

  use ExUnit.CaseTemplate

  alias Opsmaru.Incus.{Connection, Gateway}
  alias Opsmaru.Incus.Gateway.Admission
  alias Opsmaru.TestSupport.{GatewayHost, GatewayServer, RawHTTP, StreamBackend, TLSIdentity}

  using do
    quote do
      alias Opsmaru.Incus.{Connection, Gateway}
      alias Opsmaru.Incus.Gateway.Admission
      alias Opsmaru.TestSupport.{GatewayHost, GatewayServer, RawHTTP, StreamBackend, TLSIdentity}
      import Opsmaru.TestSupport.GatewayCase
    end
  end

  @auth {"authorization", "Bearer fixture-token"}
  def auth, do: @auth

  setup do
    root = Path.join(System.tmp_dir!(), "oig-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    admission = start_supervised!({Admission, max_exchanges: 8})
    {ref, port} = GatewayServer.start_http()

    on_exit(fn ->
      GatewayServer.stop(ref)
      GatewayServer.clear()
      File.rm_rf!(root)
    end)

    identity =
      TLSIdentity.generate(root, "gateway-public", "gateway.example.com")

    %{
      root: root,
      admission: admission,
      port: port,
      public_certificate: File.read!(identity.certfile)
    }
  end

  @doc "Start a scripted Unix backend; returns `{pid, connection}`."
  def backend(context, script, connection_opts \\ []) do
    path = Path.join(context.root, "incus-#{System.unique_integer([:positive])}.sock")

    pid =
      ExUnit.Callbacks.start_supervised!(
        {StreamBackend, path: path, observer: self(), script: script},
        id: make_ref()
      )

    {pid, Connection.unix!(path, Keyword.merge([owner: :fixture], connection_opts))}
  end

  @doc "Mount a gateway for `connection` with the default fixture policy."
  def mount(context, connection, opts \\ []) do
    {host_config, opts} = Keyword.pop(opts, :host_config, %{})

    gateway =
      Gateway.new!(
        [
          connection: connection,
          host: GatewayHost,
          host_config:
            Map.merge(
              %{
                observer: self(),
                ready: true,
                valid: fn _, _ -> true end,
                identity: %{
                  origin: "https://gateway.example.com:8443",
                  addresses: ["gateway.example.com:8443"],
                  certificate: context.public_certificate,
                  connection: connection,
                  api_extensions: ["certificate_update"]
                },
                authorize: &GatewayHost.default_authorize/1
              },
              host_config
            ),
          admission: context.admission
        ] ++ opts
      )

    GatewayServer.put_gateway(gateway)
    gateway
  end

  def get(context, target, headers \\ [@auth]),
    do: RawHTTP.request(context.port, "GET", target, headers)

  def native(body), do: Jason.decode!(body)

  @doc "A script answering every request with one JSON response."
  def reply(status, body, headers \\ []) do
    fn conn ->
      {conn, _, _} = StreamBackend.read_body(conn)
      StreamBackend.write(conn, StreamBackend.json(status, body, headers))
    end
  end
end
