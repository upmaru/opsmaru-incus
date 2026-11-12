import Config

config :foundation_consumer, FoundationConsumer.Endpoint,
  adapter: Phoenix.Endpoint.Cowboy2Adapter,
  http: [ip: {127, 0, 0, 1}, port: 0],
  server: true,
  secret_key_base: String.duplicate("fixture-only-host-secret-", 4)

config :logger, level: :warning
