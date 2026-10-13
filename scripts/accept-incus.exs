# Explicit opt-in only. This script never launches Macus/Incus or uses a default remote.
# See docs/real-incus-acceptance.md before supplying OPSMARU_ACCEPTANCE_CONFIG.
defmodule OpsmaruAcceptance do
  alias Opsmaru.{Context, Incus}
  alias Opsmaru.Incus.{Connection, Error, Events, Files, Model, Operation}

  def run do
    config = System.fetch_env!("OPSMARU_ACCEPTANCE_CONFIG") |> File.read!() |> Jason.decode!()
    true = config["allow_namespaced_mutations"] == true
    project = config["project"]
    true = is_binary(project) and Regex.match?(~r/\Aopsmaru-acceptance-[a-z0-9-]+\z/, project)
    report = config["report"]
    true = Path.type(report) == :absolute
    false = File.exists?(report)
    Process.put(:acceptance_journal, report)
    {:ok, _} = Application.ensure_all_started(:ssl)

    context =
      Context.new!(owner: :acceptance, identity: :verified_operator, ready?: fn -> true end)

    opts = [
      owner: :acceptance,
      timeout: 10_000,
      stream_timeout: 30_000,
      max_stream_bytes: 2_097_152
    ]

    unix = Connection.unix!(config["socket"], opts)
    [tls] = :public_key.pem_decode(File.read!(config["server_certificate"]))
    {:Certificate, der, :not_encrypted} = tls
    pin = Base.encode16(:crypto.hash(:sha256, der), case: :lower)

    https =
      Connection.https!(
        config["https"],
        opts ++
          [
            require_authenticated: true,
            tls: [
              fingerprint: pin,
              certfile: config["client_certificate"],
              keyfile: config["client_key"]
            ]
          ]
      )

    {:ok, local} = Incus.connect(unix, context)
    {:ok, remote} = Incus.connect(https, context)
    true = local.server.api_version == "1.0" and remote.server.api_version == "1.0"
    true = local.server.environment["server_version"] == config["expected_version"]
    true = remote.server.environment["server_version"] == config["expected_version"]
    verify_backend(local, remote, pin, project)

    {:ok, pool} = call(local, "GetStoragePool", %{"name" => config["pool"]})
    true = pool.metadata.data["status"] == "Created"
    record(report, %{project: project, phase: "intent", pool: config["pool"], transports: []})

    # Never retry mutations or delete resources on failure. The journal identifies
    # the unique project and each accepted operation for host reconciliation.
    nonce = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    description = "Opsmaru isolated direct-client acceptance " <> nonce

    {:ok, _} =
      call(local, "CreateProject", %{},
        body: %{
          "name" => project,
          "description" => description,
          "config" => %{"features.storage.volumes" => "true", "features.profiles" => "true"}
        }
      )

    # A cloned certificate alone does not prove shared backend state. Require
    # visibility of this run's unguessable marker before either transport suite.
    for client <- [local, remote] do
      {:ok, visible} = call(client, "GetProject", %{"name" => project})

      unless visible.metadata.data["description"] == description,
        do: raise("Acceptance project identity mismatch")
    end

    results =
      for {transport, client} <- [{"unix", local}, {"https", remote}] do
        client = Incus.project(client, project)
        result = exercise(client, transport, config["pool"], report)
        update(report, fn state -> Map.update!(state, "transports", &(&1 ++ [result])) end)
        result
      end

    # Cleanup is authorized only after both suites succeeded, scoped to this new
    # project. On a failed assertion the script stops and retains backend data.
    for {transport, client} <- [{"unix", local}, {"https", remote}] do
      {:ok, _} =
        call(Incus.project(client, project), "DeleteStoragePoolVolume", %{
          "pool" => config["pool"],
          "volType" => "custom",
          "name" => "binary-" <> transport
        })
    end

    {:ok, _} = call(local, "DeleteProject", %{"name" => project})
    {:error, %Error{http_status: 404}} = call(remote, "GetProject", %{"name" => project})

    # The library has no application callback, so it cannot own processes.
    [] = Application.spec(:opsmaru_incus, :mod)

    update(
      report,
      &Map.merge(&1, %{"phase" => "passed-and-cleaned", "passive_application" => true})
    )

    IO.puts(Jason.encode!(%{phase: "passed-and-cleaned", project: project, transports: results}))
  end

  defp verify_backend(local, remote, pin, project) do
    if certificate_pin(local.server.environment["certificate"]) != pin or
         certificate_pin(remote.server.environment["certificate"]) != pin or
         local.server.environment["server_name"] in [nil, ""] or
         local.server.environment["server_name"] != remote.server.environment["server_name"],
       do: raise("Acceptance backend identity mismatch")

    for client <- [local, remote] do
      unless match?(
               {:error, %Error{http_status: 404}},
               call(client, "GetProject", %{"name" => project})
             ),
             do: raise("Acceptance project must be absent on both transports")
    end
  end

  defp certificate_pin(pem) when is_binary(pem) and byte_size(pem) <= 1_048_576 do
    case :public_key.pem_decode(pem) do
      [{:Certificate, der, :not_encrypted}] ->
        Base.encode16(:crypto.hash(:sha256, der), case: :lower)

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp certificate_pin(_), do: nil

  defp exercise(client, transport, pool, _journal) do
    {:ok, events} = Events.subscribe(client, types: ["operation", "lifecycle"])
    volume = "binary-" <> transport
    args = %{"pool" => pool, "volType" => "custom", "name" => volume}

    {:ok, _} =
      call(client, "CreateStoragePoolVolume", %{"pool" => pool},
        body: %{
          "name" => volume,
          "type" => "custom",
          "content_type" => "filesystem",
          "config" => %{}
        }
      )

    {:ok, native} = call(client, "GetStoragePoolVolume", args)
    true = native.metadata.data["name"] == volume and native.etag != ""
    {:ok, writable} = Model.writable(native.metadata)

    body =
      writable.data
      |> Map.put("description", "#{transport} acceptance")
      |> Map.update!("config", &Map.put(&1, "user.opsmaru-acceptance", transport))

    {:ok, _} = call(client, "UpdateStoragePoolVolume", args, body: body, etag: native.etag)

    {:error, %Error{http_status: 412}} =
      call(client, "UpdateStoragePoolVolume", args, body: writable, etag: native.etag)

    {:ok, current} = call(client, "GetStoragePoolVolume", args)
    true = current.metadata.data["description"] == "#{transport} acceptance"
    binary = :binary.copy(<<0, 255, 128, 10, 13, 42, 0>>, 20_000)
    source = for <<chunk::binary-size(7_000) <- binary>>, do: chunk

    {:ok, _} =
      Files.volume_create(client, pool, "custom", volume, "/payload.bin", source, mode: 0o640)

    owner = self()
    ref = make_ref()

    sink = fn bytes ->
      send(owner, {ref, bytes})
      :ok
    end

    {:ok, info} = Files.volume_read(client, pool, "custom", volume, "/payload.bin", sink)
    received = collect(ref, [])
    true = received == binary and info.result.mode == 0o640 and info.result.type == "file"

    snapshot_args = %{"pool" => pool, "volumeType" => "custom", "volumeName" => volume}

    {:ok, accepted} =
      call(client, "CreateStoragePoolVolumeSnapshot", snapshot_args, body: %{"name" => "proof"})

    "async" = accepted.type
    {:ok, operation} = Operation.from_response(client, accepted)

    {:ok, completed} = Operation.wait(operation, timeout: 20_000)
    true = completed.url == accepted.operation and Operation.successful?(completed)
    true = operation_event(events, operation.url, System.monotonic_time(:millisecond) + 10_000, 0)
    :ok = Events.close(events)

    {:ok, deleted} =
      call(
        client,
        "DeleteStoragePoolVolumeSnapshot",
        Map.put(snapshot_args, "snapshotName", "proof")
      )

    {:ok, deletion} = Operation.from_response(client, deleted)
    {:ok, _} = Operation.wait(deletion, timeout: 20_000)
    {:ok, _} = Files.volume_delete(client, pool, "custom", volume, "/payload.bin")

    %{
      "transport" => transport,
      "inspection" => true,
      "conditional_mutation" => true,
      "stale_etag_rejected" => true,
      "binary_bytes" => byte_size(binary),
      "binary_sha256" => Base.encode16(:crypto.hash(:sha256, binary), case: :lower),
      "accepted_operation" => accepted.operation,
      "completion" => true,
      "operation_event" => true
    }
  end

  defp call(client, method, args, opts \\ []) do
    journal = Process.get(:acceptance_journal)

    if File.exists?(journal) do
      update(
        journal,
        &Map.put(&1, "last_request", %{
          "method" => method,
          "arguments" => args,
          "project" => client.connection.project,
          "outcome" => "pending"
        })
      )
    end

    result = Incus.call(client, method, args, opts)

    if File.exists?(journal) do
      {outcome, operation} =
        case result do
          {:ok, response} -> {response.type, response.operation}
          {:error, %Error{} = error} -> {Atom.to_string(error.kind), error.operation}
        end

      update(journal, fn state ->
        state = put_in(state, ["last_request", "outcome"], outcome)

        if is_binary(operation) and operation != "",
          do: Map.update(state, "operations", [operation], &Enum.uniq(&1 ++ [operation])),
          else: state
      end)
    end

    result
  end

  defp collect(ref, chunks) do
    receive do
      {^ref, bytes} -> collect(ref, [bytes | chunks])
    after
      0 -> chunks |> Enum.reverse() |> IO.iodata_to_binary()
    end
  end

  defp operation_event(events, operation_url, deadline, count) when count < 128 do
    remaining = deadline - System.monotonic_time(:millisecond)
    true = remaining > 0
    {:ok, event} = Events.next(events, remaining)

    if event.data["type"] == "operation" and
         event.data["metadata"]["id"] == List.last(String.split(operation_url, "/")),
       do: true,
       else: operation_event(events, operation_url, deadline, count + 1)
  end

  defp record(path, value) do
    File.write!(path, Jason.encode!(value, pretty: true))
    File.chmod!(path, 0o600)
  end

  defp update(path, function), do: record(path, function.(Jason.decode!(File.read!(path))))
end

OpsmaruAcceptance.run()
