defmodule OpsmaruIncus.MixProject do
  use Mix.Project

  @version "0.2.10"
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

  # priv/incus files the package ships: data read at compile time, plus the
  # reviewed policy behind the native operations document. Named one by one so
  # that generator-only input (rest-api.yaml) is never packaged;
  # `mise run check:consumer` fails if it is.
  @priv_incus ~w(README.md constants.json coverage.json endpoint-evidence.json
                 endpoint-inventory.json gateway-transfer.json inventory.json methods.json
                 models.json native-operations.json native-policy.json reference.json
                 transfer.json)

  # Hex is the only distribution route. priv/notices carries the upstream
  # licence notices.
  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url, "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"},
      files:
        ~w(lib priv/notices mix.exs README.md CHANGELOG.md LICENSE NOTICE) ++
          Enum.map(@priv_incus, &"priv/incus/#{&1}")
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
      {:nimble_pool, "~> 1.1", optional: true, runtime: false},
      {:mint_web_socket, "~> 1.0"},
      {:jason, "~> 1.4"},
      # Optional telemetry emitter for the gateway exchange catalogue.
      # Client-only consumers compile without it.
      {:telemetry, "~> 1.3", optional: true},
      # Native multipart/content-type parsing and the strict YAML subset decoder.
      {:cowlib, "~> 2.20"},
      {:yamerl, "~> 0.10"},
      # Optional native gateway adapters (Opsmaru.Incus.Gateway.*). Client-only
      # consumers compile without them; gateway modules are skipped.
      {:plug, "~> 1.16", optional: true},
      {:cowboy, "~> 2.12", optional: true},
      {:plug_cowboy, "~> 2.7", only: :test},
      # Validates the operation documents and builds the release cassette. Never a
      # runtime dependency: the documents are plain data and consumers do not
      # fetch it.
      {:tama_dex, "~> 0.1", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false}
    ]
  end
end
