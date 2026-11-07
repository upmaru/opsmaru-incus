# Explicit operator entrypoint. Modules remain passive when required separately.
Code.require_file("gateway-acceptance-host.exs", __DIR__)
Code.require_file("gateway_live_scenarios.exs", __DIR__)

config =
  System.fetch_env!("OPSMARU_GATEWAY_ACCEPTANCE_CONFIG")
  |> OpsmaruGatewayLiveScenarios.load_config!()
  |> OpsmaruGatewayLiveScenarios.prepare!()

OpsmaruGatewayAcceptance.run(config, &OpsmaruGatewayLiveScenarios.run/1)
