# test/consumer is a separate Mix project with its own Phoenix formatting rules.
[
  inputs: [
    "{mix,.formatter,.credo}.exs",
    "{config,lib}/**/*.{ex,exs}",
    "test/*.{ex,exs}",
    "test/{support,reference}/**/*.{ex,exs}",
    "scripts/**/*.exs"
  ]
]
