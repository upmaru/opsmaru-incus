import Config

if config_env() == :test do
  config :logger, level: :warning

  # Socket-identity assertions exercise reuse and the handoff under CI load.
  # Production uses 5 ms, and a suspended binding still exercises fallback.
  config :opsmaru_incus, pool_acquisition_ms: 100
end
