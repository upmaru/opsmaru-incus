%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/", "config/", "scripts/**/*.exs", "mix.exs"],
        excluded: [
          "test/consumer/_build/",
          "test/consumer/deps/",
          # Verbatim Macus transfer; its digest is checked in
          # priv/incus/gateway-transfer.json, so it is not restyled here.
          "test/support/gateway/cowboy_upgrade_fixture.ex"
        ]
      },
      strict: true,
      checks: %{
        extra: [
          # Protocol state machines and fixture scripts commonly nest a case
          # inside a reduction. Keep finite limits and flag larger handlers.
          {Credo.Check.Refactor.Nesting, max_nesting: 3},
          {Credo.Check.Refactor.CyclomaticComplexity, max_complexity: 12}
        ]
      }
    }
  ]
}
