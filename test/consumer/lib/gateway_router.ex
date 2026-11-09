defmodule FoundationConsumer.GatewayRouter do
  @moduledoc false
  use Plug.Router
  alias Opsmaru.Incus.Gateway.Plug, as: GatewayPlug

  def gateway, do: Agent.get(FoundationConsumer.GatewayConfig, & &1)
  def configure(gateway), do: Agent.update(FoundationConsumer.GatewayConfig, fn _ -> gateway end)

  plug(:match)
  plug(:dispatch)

  get "/runtime" do
    send_resp(conn, 200, "consumer-runtime")
  end

  post "/mcp" do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    send_resp(conn, 200, "consumer-mcp:" <> body)
  end

  get "/" do
    GatewayPlug.call(conn, {:dynamic, {__MODULE__, :gateway, []}})
  end

  match "/1.0/*path" do
    GatewayPlug.call(conn, {:dynamic, {__MODULE__, :gateway, []}})
  end

  match _ do
    send_resp(conn, 404, "consumer-route-not-found")
  end
end
