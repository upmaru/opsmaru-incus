defmodule FoundationConsumer.GatewayEndpoint do
  @moduledoc "Explicitly started, consumer-owned native gateway endpoint."
  use Phoenix.Endpoint, otp_app: :foundation_consumer

  plug(FoundationConsumer.GatewayRouter)

  def dispatch do
    opts = %{
      gateway: {FoundationConsumer.GatewayRouter, :gateway, []},
      fallback: {Plug.Cowboy.Handler, {__MODULE__, init([])}}
    }

    :cowboy_router.compile([
      {:_, [{:_, Opsmaru.Incus.Gateway.CowboyHandler, opts}]}
    ])
  end
end
