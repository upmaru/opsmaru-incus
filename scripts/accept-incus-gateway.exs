# The real scenario driver must be source-owned and reviewed before activation.
# Loading configuration alone must not start a host or create backend state.
Code.require_file("gateway-acceptance-host.exs", __DIR__)

raise "Gateway live scenarios are not installed; acceptance remains unrun. Use OpsmaruGatewayAcceptance.run/2 from a reviewed source-owned driver."
