defmodule FoundationConsumer.MixProject do
  use Mix.Project

  def project do
    [app: :foundation_consumer, version: "0.1.0", elixir: "~> 1.19.5", deps: deps()]
  end

  def application, do: [mod: {FoundationConsumer.Application, []}, extra_applications: [:logger]]

  defp deps do
    revision = System.fetch_env!("OPSMARU_FIXTURE_REVISION")
    unless Regex.match?(~r/\A[0-9a-f]{40}\z/, revision), do: raise("immutable revision required")

    [
      {:opsmaru,
       git: System.get_env("OPSMARU_FIXTURE_REPOSITORY", "https://github.com/upmaru/opsmaru.git"),
       ref: revision},
      {:phoenix, "1.8.15"},
      {:mint, "1.11.0"},
      {:plug_cowboy, "2.9.0"},
      {:cowboy, "2.19.0"},
      {:tama_mcp, "0.1.1"},
      {:jason, "~> 1.4"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"}
    ]
  end
end
