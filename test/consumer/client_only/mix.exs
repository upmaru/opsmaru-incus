defmodule ClientOnlyConsumer.MixProject do
  use Mix.Project

  # A client-only consumer: no tama_mcp, Plug, Cowboy or Phoenix.
  def project do
    [app: :client_only_consumer, version: "0.1.0", elixir: "~> 1.19.5", deps: deps()]
  end

  def application, do: [extra_applications: [:logger]]

  defp deps do
    revision = System.fetch_env!("OPSMARU_INCUS_FIXTURE_REVISION")
    unless Regex.match?(~r/\A[0-9a-f]{40}\z/, revision), do: raise("immutable revision required")

    [
      {:opsmaru_incus,
       git:
         System.get_env(
           "OPSMARU_INCUS_FIXTURE_REPOSITORY",
           "https://github.com/upmaru/opsmaru-incus.git"
         ),
       ref: revision},
      {:jason, "~> 1.4"}
    ]
  end
end
