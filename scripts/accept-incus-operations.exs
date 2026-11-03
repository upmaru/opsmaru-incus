# Explicit opt-in only. This script never launches Macus/Incus or uses a default remote.
# See docs/real-incus-acceptance.md ("Shared operations") before supplying
# OPSMARU_OPERATIONS_ACCEPTANCE_CONFIG. It exercises the shared operations through
# Opsmaru.Incus.Operations.run/3 with a fixed acceptance host binding.
defmodule OpsmaruOperationsAcceptance.Host do
  @behaviour Opsmaru.Incus.Operations.Host

  # The caller is the acceptance binding itself: one verified backend and project.
  @impl true
  def binding(%{client: client}, _operation), do: {:ok, client}

  @impl true
  def authorize(%{project: project}, _operation, input),
    do: if(Map.get(input, "project", project) == project, do: :ok, else: {:error, :project})
end

defmodule OpsmaruOperationsAcceptance do
  alias Opsmaru.Incus
  alias Opsmaru.Incus.{Connection, Context, Error, Operations}

  def run do
    config =
      System.fetch_env!("OPSMARU_OPERATIONS_ACCEPTANCE_CONFIG") |> File.read!() |> Jason.decode!()

    true = config["allow_namespaced_mutations"] == true
    project = config["project"]
    true = is_binary(project) and Regex.match?(~r/\Aopsmaru-acceptance-[a-z0-9-]+\z/, project)
    report = config["report"]
    true = Path.type(report) == :absolute
    false = File.exists?(report)
    image = config["image"]
    true = is_binary(image) and image != ""
    {:ok, _} = Application.ensure_all_started(:ssl)

    context =
      Context.new!(owner: :acceptance, identity: :verified_operator, ready?: fn -> true end)

    # A 65 s request timeout lets the tools use their full 60 s native wait.
    opts = [
      owner: :acceptance,
      timeout: 65_000,
      stream_timeout: 60_000,
      max_stream_bytes: 2_097_152
    ]

    transports = [{"unix", Connection.unix!(config["socket"], opts)}] ++ https(config, opts)

    clients =
      for {name, connection} <- transports do
        {:ok, client} = Incus.connect(connection, context)
        true = client.server.environment["server_version"] == config["expected_version"]

        {:error, %Error{http_status: 404}} =
          Incus.call(client, "GetProject", %{"name" => project})

        {name, client}
      end

    record(report, %{"project" => project, "phase" => "intent", "steps" => []})
    {_, local} = hd(clients)

    # Images and profiles come from the default project, so the run needs only
    # the operator's local image; no remote or credential enters tool input.
    {:ok, _} =
      Incus.call(local, "CreateProject", %{},
        body: %{
          "name" => project,
          "description" => "Opsmaru isolated shared-operations acceptance",
          "config" => %{"features.images" => "false", "features.profiles" => "false"}
        }
      )

    for {transport, client} <- clients, do: exercise(client, transport, project, image, report)

    # Cleanup is authorized only after every suite passed; failures keep state.
    {:ok, _} = Incus.call(local, "DeleteProject", %{"name" => project})
    [] = Application.spec(:opsmaru_incus, :mod)
    update(report, &Map.put(&1, "phase", "passed-and-cleaned"))
    IO.puts(Jason.encode!(%{phase: "passed-and-cleaned", project: project, report: report}))
  end

  defp https(%{"https" => url} = config, opts) when is_binary(url) do
    [{:Certificate, der, :not_encrypted}] =
      :public_key.pem_decode(File.read!(config["server_certificate"]))

    pin = Base.encode16(:crypto.hash(:sha256, der), case: :lower)

    [
      {"https",
       Connection.https!(
         url,
         opts ++
           [
             require_authenticated: true,
             tls: [
               fingerprint: pin,
               certfile: config["client_certificate"],
               keyfile: config["client_key"]
             ]
           ]
       )}
    ]
  end

  defp https(_, _), do: []

  defp exercise(client, transport, project, image, report) do
    caller = %{client: client, project: project}
    name = "ops-" <> transport

    op = fn operation, input ->
      step(report, transport, operation, Map.put(input, "project", project), caller)
    end

    # Inspection, and a denied project that never reaches the backend.
    %{"item" => %{"api_version" => "1.0"}} = op.("incus_server_get", %{})
    %{"item" => %{"name" => ^project}} = op.("incus_project_get", %{"name" => project})
    %{"items" => [], "count" => 0} = op.("incus_instance_list", %{})

    {:error, %{"kind" => "unauthorized"}} =
      Operations.run("incus_instance_list", %{"project" => "default"},
        host: OpsmaruOperationsAcceptance.Host,
        caller: caller,
        scopes: ["incus.read"]
      )

    # A scoped mutation and operation polling by native identity.
    created =
      op.("incus_instance_create", %{
        "name" => name,
        "image" => %{"alias" => image},
        "start" => true,
        "wait_seconds" => 60
      })

    %{"status" => "completed", "operation_id" => id} = created

    %{"status" => "completed", "operation_id" => ^id} =
      op.("incus_operation_get", %{"operation_id" => id})

    %{"status" => "completed"} =
      op.("incus_operation_wait", %{"operation_id" => id, "wait_seconds" => 1})

    %{"item" => %{"status" => "Running"}} = op.("incus_instance_state_get", %{"name" => name})

    # Bounded exec: output, exit status, truncation and a killed timeout.
    %{"status" => "completed", "exit_status" => 3, "stdout" => "opsmaru\n", "stderr" => "err\n"} =
      op.("incus_instance_exec", %{
        "instance" => name,
        "command" => ["sh", "-c", "cat; echo err >&2; exit 3"],
        "stdin" => "opsmaru\n"
      })

    %{"stdout_truncated" => true, "stdout_bytes" => 100_000} =
      op.("incus_instance_exec", %{
        "instance" => name,
        "command" => ["sh", "-c", "yes a | head -c 100000"]
      })

    %{"timed_out" => true, "exit_status" => 137} =
      op.("incus_instance_exec", %{
        "instance" => name,
        "command" => ["sleep", "60"],
        "timeout_seconds" => 2
      })

    # Snapshot, destructive restore with confirmation, then confirmed deletions.
    %{"status" => "completed"} =
      op.("incus_instance_snapshot_create", %{"instance" => name, "name" => "s1"})

    {:error, %{"kind" => "confirmation_required"}} =
      Operations.run(
        "incus_instance_snapshot_restore",
        %{"project" => project, "instance" => name, "snapshot" => "s1", "confirm" => "yes"},
        host: OpsmaruOperationsAcceptance.Host,
        caller: caller,
        scopes: Operations.scopes()
      )

    %{"status" => "completed"} =
      op.("incus_instance_snapshot_restore", %{
        "instance" => name,
        "snapshot" => "s1",
        "confirm" => name <> "/s1"
      })

    %{"status" => "completed"} =
      op.("incus_instance_snapshot_delete", %{
        "instance" => name,
        "name" => "s1",
        "confirm" => name <> "/s1"
      })

    %{"status" => "completed"} =
      op.("incus_instance_state_update", %{
        "name" => name,
        "action" => "stop",
        "force" => true,
        "wait_seconds" => 60
      })

    %{"status" => "completed"} =
      op.("incus_instance_delete", %{"name" => name, "confirm" => name, "wait_seconds" => 60})

    %{"items" => []} = op.("incus_instance_list", %{})
  end

  # Each step is journaled before and after; nothing is retried.
  defp step(report, transport, operation, input, caller) do
    input = if operation == "incus_server_get", do: Map.delete(input, "project"), else: input
    entry = %{"transport" => transport, "operation" => operation, "outcome" => "pending"}
    update(report, &Map.update!(&1, "steps", fn steps -> steps ++ [entry] end))

    result =
      Operations.run(operation, input,
        host: OpsmaruOperationsAcceptance.Host,
        caller: caller,
        scopes: Operations.scopes()
      )

    summary =
      case result do
        {:ok, value} ->
          Map.take(value, ["status", "operation_id", "exit_status", "timed_out", "count"])

        {:error, error} ->
          %{"error" => error}
      end

    update(report, fn state ->
      Map.update!(
        state,
        "steps",
        &(List.delete_at(&1, -1) ++ [Map.merge(entry, %{"outcome" => summary})])
      )
    end)

    case result do
      {:ok, value} -> value
      {:error, error} -> raise "#{transport} #{operation} failed: #{inspect(error)}"
    end
  end

  defp record(path, value) do
    File.write!(path, Jason.encode!(value, pretty: true))
    File.chmod!(path, 0o600)
  end

  defp update(path, function), do: record(path, function.(Jason.decode!(File.read!(path))))
end

OpsmaruOperationsAcceptance.run()
