defmodule FoundationConsumer.Application do
  use Application

  def start(_, _) do
    Supervisor.start_link(
      [
        %{
          id: :host_runtime,
          start: {Agent, :start_link, [fn -> false end, [name: FoundationConsumer.Runtime]]}
        },
        FoundationConsumer.Endpoint
      ],
      strategy: :one_for_one,
      name: FoundationConsumer.Supervisor
    )
  end
end

defmodule FoundationConsumer.Endpoint do
  use Phoenix.Endpoint, otp_app: :foundation_consumer
  plug :respond
  defp respond(conn, _), do: Plug.Conn.send_resp(conn, 200, "consumer-owned endpoint")
end
