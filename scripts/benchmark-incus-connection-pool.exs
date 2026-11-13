# Run with mix run --no-start. Supply a private configuration for an isolated
# project. This runner uses only buffered reads and the existing client.
defmodule Opsmaru.Incus.PoolBaseline do
  alias Opsmaru.Incus
  alias Opsmaru.Incus.{Connection, Context, Error, Operations}

  defmodule Host do
    @behaviour Operations.Host

    @impl true
    def binding({connection, context}, "incus_instance_list"), do: {:ok, connection, context}

    @impl true
    def authorize({%{project: project}, _}, "incus_instance_list", %{"project" => project}),
      do: :ok

    def authorize(_, _, _), do: {:error, :project}
  end

  def run(config) do
    project = Map.get(config, "project")
    operation = Map.get(config, "operation")
    samples = Map.get(config, "samples", 100)
    warmup = Map.get(config, "warmup", 10)

    unless config["isolated_benchmark"] == true and valid_name?(project) and project != "default" and
             (is_nil(operation) or valid_name?(operation)) and samples in 1..1_000 and
             warmup in 0..100 do
      raise ArgumentError,
            "expected explicit isolation, a named project and bounded sample counts"
    end

    opts = [owner: :pool_baseline, project: project]
    context = Context.new!(owner: :pool_baseline, identity: :operator, ready?: fn -> true end)
    {:ok, _} = Application.ensure_all_started(:ssl)

    bindings = [
      {"unix", Connection.unix!(Map.fetch!(config, "socket"), opts)}
      | https(config, opts)
    ]

    verified = Enum.map(bindings, &verify(&1, context, project, operation))

    identities =
      Enum.map(verified, fn {_, client, record} -> {server_identity(client), record} end)

    unless length(Enum.uniq(identities)) == 1,
      do: raise("bindings returned different Incus server or project records")

    results =
      for {transport, client, _} <- verified, into: %{} do
        measurements =
          for {label, request} <- workloads(client, project, operation), into: %{} do
            {label, measure(request, samples, warmup)}
          end

        {transport, measurements}
      end

    [{_, client, _} | _] = verified

    %{
      evidence: "read-only transport baseline",
      incus: client.server.environment["server_version"],
      otp: System.otp_release(),
      samples: samples,
      warmup: warmup,
      operation_poll: if(operation, do: "sampled", else: "operator did not supply an operation"),
      tls_resumption: "unmeasured by the existing client",
      incus_cpu: "requires host-side measurement over matching workload windows",
      results: results
    }
  end

  defp https(%{"https" => https, "tls" => tls}, opts) do
    tls =
      Enum.flat_map([:certfile, :keyfile, :cacertfile, :fingerprint], fn key ->
        case Map.fetch(tls, Atom.to_string(key)) do
          {:ok, value} -> [{key, value}]
          :error -> []
        end
      end)

    [
      {"verified_https",
       Connection.https!(https, opts ++ [tls: tls, require_authenticated: true])}
    ]
  end

  defp https(config, _) do
    if Map.has_key?(config, "https") or Map.has_key?(config, "tls"),
      do: raise(ArgumentError, "verified HTTPS requires an origin and TLS options")

    []
  end

  defp verify({transport, connection}, context, project, operation) do
    client = checked(Incus.connect(connection, context), "discovery")
    record = checked(Incus.call(client, "GetProject", %{"name" => project}), "project preflight")

    if operation,
      do:
        checked(Incus.call(client, "GetOperation", %{"uuid" => operation}), "operation preflight")

    {transport, client, record.metadata}
  end

  defp server_identity(client) do
    Map.take(client.server.environment, ["server_name", "server_version"])
  end

  defp workloads(client, project, operation) do
    binding = {client.connection, client.context}

    [
      {"buffered_get", fn -> Incus.raw_query(client, "GET", "/1.0/instances") end},
      {"discovery", fn -> Incus.connect(client.connection, client.context) end},
      {"shared_inspection",
       fn ->
         Operations.run("incus_instance_list", %{"project" => project},
           host: Host,
           caller: binding,
           scopes: ["incus.read"]
         )
       end}
    ] ++ operation_workload(client, operation)
  end

  defp operation_workload(_, nil), do: []

  defp operation_workload(client, id) do
    [{"operation_poll", fn -> Incus.call(client, "GetOperation", %{"uuid" => id}) end}]
  end

  defp measure(request, samples, warmup) do
    for _ <- List.duplicate(nil, warmup), do: checked(request.(), "warmup")

    mint_connect = {Mint.HTTP, :connect, 4}
    ssl_connect = {:ssl, :connect, 4}
    :erlang.trace_pattern(mint_connect, true, [:call_count])
    :erlang.trace_pattern(ssl_connect, true, [:call_count])

    try do
      timings =
        for _ <- 1..samples do
          {time, result} = :timer.tc(request)
          {time, outcome(result)}
        end

      {:call_count, attempts} = :erlang.trace_info(mint_connect, :call_count)
      {:call_count, tls_attempts} = :erlang.trace_info(ssl_connect, :call_count)
      successes = for {time, :ok} <- timings, do: time
      errors = for {_, {:error, kind}} <- timings, do: kind
      sorted = Enum.sort(successes)

      %{
        p50_us: percentile(sorted, 50),
        p95_us: percentile(sorted, 95),
        successful_samples: length(successes),
        connection_attempts: attempts,
        tls_connect_attempts: tls_attempts,
        errors: Enum.frequencies(errors)
      }
    after
      :erlang.trace_pattern(mint_connect, false, [:call_count])
      :erlang.trace_pattern(ssl_connect, false, [:call_count])
    end
  end

  defp percentile([], _), do: nil
  defp percentile(sorted, rank), do: Enum.at(sorted, div(length(sorted) * rank + 99, 100) - 1)

  defp checked({:ok, value}, _), do: value
  defp checked(error, step), do: raise("#{step} failed (#{elem(outcome(error), 1)})")

  defp outcome({:ok, _}), do: :ok
  defp outcome({:error, %Error{kind: kind}}) when is_atom(kind), do: {:error, kind}
  defp outcome({:error, %{"kind" => kind}}) when is_binary(kind), do: {:error, kind}
  defp outcome(_), do: {:error, :unexpected_result}

  defp valid_name?(name),
    do: is_binary(name) and Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9_-]{0,127}\z/, name)
end

config =
  "OPSMARU_POOL_BASELINE_CONFIG"
  |> System.fetch_env!()
  |> File.read!()
  |> Jason.decode!()

config |> Opsmaru.Incus.PoolBaseline.run() |> Jason.encode!(pretty: true) |> IO.puts()
