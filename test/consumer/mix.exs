defmodule FoundationConsumer.MixProject do
  use Mix.Project

  def project do
    [
      app: :foundation_consumer,
      version: "0.1.0",
      elixir: "~> 1.19.5",
      elixirc_paths: ["lib", "test/support"],
      deps: deps()
    ]
  end

  def application, do: [mod: {FoundationConsumer.Application, []}, extra_applications: [:logger]]

  defp deps do
    # scripts/check-consumer.py extracts the `mix hex.build` tarball here, so the
    # consumer compiles exactly the files the Hex package publishes.
    package = System.fetch_env!("OPSMARU_INCUS_PACKAGE_PATH")

    [
      {:opsmaru_incus, path: package},
      {:phoenix, "1.8.15"},
      {:mint, "1.11.0"},
      {:nimble_pool, "~> 1.1", runtime: false},
      {:plug_cowboy, "2.9.0"},
      {:cowboy, "2.19.0"},
      {:tama_mcp, "0.1.1"},
      {:jason, "~> 1.4"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"}
    ]
  end
end
