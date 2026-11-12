defmodule ClientOnlyConsumer.MixProject do
  use Mix.Project

  # A client-only consumer: no tama_mcp, Plug, Cowboy or Phoenix.
  def project do
    [app: :client_only_consumer, version: "0.1.0", elixir: "~> 1.19.5", deps: deps()]
  end

  def application, do: [extra_applications: [:logger]]

  defp deps do
    # scripts/check-consumer.py extracts the `mix hex.build` tarball here, so the
    # consumer compiles exactly the files the Hex package publishes.
    package = System.fetch_env!("OPSMARU_INCUS_PACKAGE_PATH")

    [
      {:opsmaru_incus, path: package},
      {:jason, "~> 1.4"}
    ]
  end
end
