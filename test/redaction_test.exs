defmodule Opsmaru.Incus.RedactionTest do
  @moduledoc "Process status of owned channels keeps OTP's keys and hides state, messages and logs."
  use ExUnit.Case, async: true

  alias Opsmaru.Incus.{DynamicConsole, EventListener, RawChannel, SFTP, WebSocket}

  @secret "0123456789abcdef-secret"

  test "format_status/1 returns every given key with the secret-bearing ones redacted" do
    status = %{
      state: %{secret: @secret},
      message: {:send, @secret},
      log: [{:in, @secret}],
      reason: :normal,
      name: self()
    }

    for module <- [DynamicConsole, EventListener, RawChannel, SFTP, WebSocket] do
      formatted = module.format_status(status)
      assert Map.keys(formatted) == Map.keys(status), inspect(module)
      assert formatted.message == :redacted and formatted.log == [], inspect(module)
      refute inspect(formatted.state) =~ @secret, inspect(module)
      assert formatted.reason == :normal and formatted.name == self(), inspect(module)

      # A status without a message or log gains neither key.
      assert Map.keys(module.format_status(%{state: :any})) == [:state], inspect(module)
    end
  end

  test ":sys.get_status shows the redacted state, not OTP's unknown-key fallback" do
    defmodule Probe do
      use GenServer
      def init(state), do: {:ok, state}
      def format_status(status), do: DynamicConsole.format_status(status)
    end

    {:ok, pid} = GenServer.start_link(Probe, %{secret: @secret})
    {:status, _, _, items} = :sys.get_status(pid)
    status = inspect(items)
    assert status =~ "native dynamic console redacted"
    refute status =~ @secret or status =~ "unknown keys"
  end
end
