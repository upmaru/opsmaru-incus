defmodule Opsmaru.Incus.GatewayMigrationInterruptionTest do
  use Opsmaru.TestSupport.GatewayCase, async: true

  for kind <- [:instance, :snapshot], mode <- [:relay, :pull, :push] do
    test "#{kind} #{mode} interrupted migration requests are never replayed or cancelled",
         context do
      observer = self()

      for role <- [:source, :target], loss <- [:backend, :frontend] do
        target = target(unquote(kind), role)
        body = body(unquote(mode), role)

        {fixture, connection} =
          backend(context, fn conn ->
            {conn, _, _} = StreamBackend.read_body(conn)
            send(observer, {:migration_received, self(), conn.head.method, conn.head.target})

            if loss == :frontend do
              send(observer, {:migration_closed, self(), StreamBackend.await_close(conn)})
            end
          end)

        mount(context, connection,
          max_lifetime: 500,
          idle_timeout: 200,
          callback_timeout: 25,
          recheck_interval: 100
        )

        case loss do
          :backend ->
            response = RawHTTP.request(context.port, "POST", target, [auth()], body)
            assert response.status == 502
            assert native(response.body)["metadata"]["gateway"]["outcome"] == "uncertain"
            assert_receive {:migration_received, _, "POST", ^target}

          :frontend ->
            client = RawHTTP.connect(context.port)

            RawHTTP.send!(client, [
              RawHTTP.head("POST", target, [
                auth(),
                {"content-length", to_string(byte_size(body))}
              ]),
              body
            ])

            assert_receive {:migration_received, worker, "POST", ^target}, 1_000
            {transport, socket} = client
            transport.close(socket)
            assert_receive {:migration_closed, ^worker, :closed}, 1_000
        end

        # This accounting occurs after the request was processed and the local
        # exchange ended. Any gateway replay/cancellation would be a second
        # backend connection; no native retrying client is involved here.
        await_released(context.admission)
        assert StreamBackend.accepted(fixture) == 1
      end
    end
  end

  defp await_released(admission, remaining \\ 100)
  defp await_released(admission, 0), do: assert(Admission.count(admission) == 0)

  defp await_released(admission, remaining) do
    if Admission.count(admission) == 0,
      do: :ok,
      else:
        (
          Process.sleep(10)
          await_released(admission, remaining - 1)
        )
  end

  defp target(:instance, :source), do: "/1.0/instances/source?project=allowed"
  defp target(:snapshot, :source), do: "/1.0/instances/source/snapshots/snapshot?project=allowed"
  defp target(_, :target), do: "/1.0/instances?project=allowed"

  defp body(mode, :target),
    do: Jason.encode!(%{name: "copied", source: %{type: "migration", mode: mode}})

  defp body(mode, :source), do: Jason.encode!(%{migration: true, live: false, mode: mode})
end
