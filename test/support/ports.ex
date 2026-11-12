defmodule Opsmaru.TestSupport.Ports do
  @moduledoc """
  TCP ports for listeners a test must name before the listener binds, such as
  an acceptance script configured with an explicit HTTPS origin.

  Choosing with `listen(0)`, closing, and binding later races: the kernel may
  give that ephemeral port to any other socket in between, including another
  async test's outbound connection or `listen(0)` listener. These ports sit
  below the Linux (32768-60999) and macOS (49152-65535) ephemeral ranges, so the
  kernel never assigns them on its own, and one VM-wide counter means no two
  tests are handed the same port. Each candidate is probe-bound without
  `reuseaddr`, skipping any port that is already in use on the machine.
  """

  @first 20_000
  @last 31_999
  @span @last - @first + 1

  @doc "Called once by `test_helper.exs` before any test runs."
  def init do
    counter = :atomics.new(1, signed: false)
    # Start at a random offset so concurrent suites on one machine rarely meet.
    :atomics.put(counter, 1, :rand.uniform(@span))
    :persistent_term.put(__MODULE__, counter)
    :ok
  end

  @doc "A port that is free now and that no other test in this VM will receive."
  def reserve!(ip \\ {127, 0, 0, 1}), do: reserve!(ip, @span)

  defp reserve!(_ip, 0), do: raise("no free test port in #{@first}..#{@last}")

  defp reserve!(ip, attempts) do
    port = @first + rem(:atomics.add_get(:persistent_term.get(__MODULE__), 1, 1), @span)

    case :gen_tcp.listen(port, ip: ip, reuseaddr: false) do
      {:ok, socket} ->
        :ok = :gen_tcp.close(socket)
        port

      {:error, :eaddrinuse} ->
        reserve!(ip, attempts - 1)
    end
  end
end
