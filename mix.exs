defmodule OpsmaruIncus.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/upmaru/opsmaru-incus"

  def project do
    [
      app: :opsmaru_incus,
      version: @version,
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      # test/consumer is a separate Mix project run by scripts/check-consumer.py.
      test_load_filters: [&(String.ends_with?(&1, "_test.exs") and not consumer?(&1))],
      test_ignore_filters: [&consumer?/1],
      start_permanent: false,
      deps: deps(),
      description:
        "Portable native Incus client, embeddable native gateway and shared Incus operations",
      source_url: @source_url,
      homepage_url: @source_url,
      package: package(),
      docs: docs()
    ]
  end

  # A pure library: no application callback, so loading or starting it
  # never creates processes, listeners, state or backend connections.
  def application do
    [extra_applications: [:logger, :ssl, :public_key, :crypto]]
  end

  # Hex is the only distribution route. priv/incus is read at compile time, and
  # priv/notices carries the upstream licence notices.
  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url, "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"},
      files: ~w(lib priv/incus priv/notices mix.exs README.md CHANGELOG.md LICENSE NOTICE)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: [
        "README.md",
        "CHANGELOG.md",
        "docs/embedding.md",
        "docs/incus-client.md",
        "docs/incus-operations.md",
        "docs/gateway.md"
      ]
    ]
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
      # Optional native gateway adapters (Opsmaru.Incus.Gateway.*). Client-only
      # consumers compile without them; gateway modules are skipped.
      {:plug, "~> 1.16", optional: true},
      {:cowboy, "~> 2.12", optional: true},
      {:plug_cowboy, "~> 2.7", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false}
    ]
  end
end
