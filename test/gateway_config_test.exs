defmodule Opsmaru.Incus.GatewayConfigTest do
  # Task 1.1: passive configuration, host contract and optional dependencies.
  use ExUnit.Case, async: false

  alias Opsmaru.Incus.{Connection, Gateway}
  alias Opsmaru.TestSupport.GatewayHost

  defmodule NotAHost do
    def ready?(_), do: true
  end

  setup do
    connection = Connection.unix!("/nonexistent/opsmaru-gateway.sock", owner: :fixture)
    %{connection: connection}
  end

  test "construction under hostile web environment values is passive", %{connection: connection} do
    previous = for key <- ["PHX_SERVER", "PORT"], do: {key, System.get_env(key)}
    System.put_env("PHX_SERVER", "true")
    System.put_env("PORT", "4000")

    try do
      processes = MapSet.new(Process.list())
      ports = MapSet.new(Port.list())
      {:ok, _} = Application.ensure_all_started(:opsmaru_incus)

      gateway =
        Gateway.new!(
          connection: connection,
          host: GatewayHost,
          host_config: %{secret: "host-private-token"},
          admission: :no_such_admission
        )

      # No application callback, so nothing can be started on load.
      assert Application.spec(:opsmaru_incus, :mod) == []
      # The backend socket does not exist; construction never touched it.
      assert gateway.connection == connection
      assert MapSet.difference(MapSet.new(Process.list()), processes) |> Enum.empty?()
      assert MapSet.difference(MapSet.new(Port.list()), ports) |> Enum.empty?()
      refute :ranch.info() |> Map.keys() |> Enum.any?()
    after
      for {key, value} <- previous,
          do: if(value, do: System.put_env(key, value), else: System.delete_env(key))
    end
  end

  test "defaults derive from the fixed connection", %{connection: connection} do
    gateway = Gateway.new!(connection: connection, host: GatewayHost, admission: :admission)
    assert gateway.idle_timeout == connection.stream_timeout
    assert gateway.max_request_bytes == connection.max_stream_bytes
    assert gateway.max_response_bytes == connection.max_stream_bytes
    assert gateway.max_chunk_bytes == connection.max_chunk_bytes
    assert gateway.callback_timeout == 1_000
  end

  test "invalid configuration fails before any use", %{connection: connection} do
    base = [connection: connection, host: GatewayHost, admission: :admission]

    for opts <- [
          Keyword.delete(base, :connection),
          Keyword.put(base, :connection, "unix:///var/lib/incus/unix.socket"),
          Keyword.delete(base, :host),
          Keyword.put(base, :host, NotAHost),
          Keyword.put(base, :host, :not_loaded_module),
          Keyword.delete(base, :admission),
          Keyword.put(base, :admission, "admission"),
          base ++ [callback_timeout: 0],
          base ++ [callback_timeout: 60_000],
          base ++ [idle_timeout: :infinity],
          base ++ [max_chunk_bytes: 2_000_000],
          base ++ [max_header_bytes: 10],
          base ++ [unknown: true],
          base ++ [host: GatewayHost]
        ] do
      assert_raise ArgumentError, fn -> Gateway.new!(opts) end
    end
  end

  test "inspect redacts the backend, host configuration and request credentials",
       %{connection: connection} do
    gateway =
      Gateway.new!(
        connection: connection,
        host: GatewayHost,
        host_config: %{secret: "host-private-token"},
        admission: :admission
      )

    rendered = inspect(gateway)
    refute rendered =~ "host-private-token"
    refute rendered =~ "opsmaru-gateway.sock"
    assert rendered =~ "redacted"

    request = %Opsmaru.Incus.Gateway.Request{
      protocol: :http,
      method: "GET",
      path: "/1.0",
      query: "",
      peer: %{address: {127, 0, 0, 1}, port: 1, certificate: nil},
      authorization: "Bearer private-bearer"
    }

    refute inspect(request) =~ "private-bearer"
  end

  test "gateway adapters compile because Plug is present here, and are optional deps" do
    assert Code.ensure_loaded?(Opsmaru.Incus.Gateway.Plug)
    deps = Mix.Project.config()[:deps]
    assert {:plug, "~> 1.16", optional: true} in deps
    assert {:cowboy, "~> 2.12", optional: true} in deps
    # Client-only consumers (test/consumer/client_only) build without either.
  end
end
