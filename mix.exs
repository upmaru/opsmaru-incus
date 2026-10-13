defmodule OpsmaruIncus.MixProject do
  use Mix.Project

  @source_url "https://github.com/upmaru/opsmaru-incus"

  def project do
    [
      app: :opsmaru_incus,
      version: "0.1.0",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      # test/consumer is a separate Mix project run by scripts/check-consumer.py.
      test_load_filters: [&(String.ends_with?(&1, "_test.exs") and not consumer?(&1))],
      test_ignore_filters: [&consumer?/1],
      start_permanent: false,
      deps: deps(),
      description: "Portable native Incus client with explicit host-supplied connections",
      source_url: @source_url
    ]
  end

  # A pure library: no application callback, so loading or starting it
  # never creates processes, listeners, state or backend connections.
  def application do
    [extra_applications: [:logger, :ssl, :public_key, :crypto]]
  end

  defp consumer?(path), do: String.starts_with?(path, "test/consumer/")

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Ranges, not exact pins: consumers (Macus, central Opsmaru) resolve the
  # exact versions in their own lockfiles.
  defp deps do
    [
      {:mint, "~> 1.11"},
      {:mint_web_socket, "~> 1.0"},
      {:jason, "~> 1.4"},
      # Native multipart/content-type parsing and the strict YAML subset decoder.
      {:cowlib, "~> 2.20"},
      {:yamerl, "~> 0.10"},
      {:plug, "~> 1.20", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end
end
