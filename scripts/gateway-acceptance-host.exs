# Explicit acceptance host only. Requiring this file defines modules and does no I/O.
defmodule OpsmaruGatewayAcceptance.Journal do
  @moduledoc false

  defmodule FileIO do
    @moduledoc false
    def open(path, modes), do: :file.open(String.to_charlist(path), modes)
    def chmod(path, mode), do: File.chmod(path, mode)
    def write(file, bytes), do: :file.write(file, bytes)
    def sync(file), do: :file.sync(file)
    def close(file), do: :file.close(file)
    def rename(source, target), do: File.rename(source, target)
    def remove(path), do: File.rm(path)
  end

  def create!(path, data, io \\ FileIO) do
    write_file!(path, data, io)
    sync_directory!(Path.dirname(path), io)
  end

  def replace!(path, data, io \\ FileIO) do
    directory = Path.dirname(path)

    temporary =
      Path.join(
        directory,
        ".gateway-journal-" <>
          Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
      )

    try do
      write_file!(temporary, data, io)
      check!(io.rename(temporary, path), path, "replace acceptance journal")
      sync_directory!(directory, io)
    after
      io.remove(temporary)
    end
  end

  defp write_file!(path, data, io) do
    file = open!(path, [:raw, :binary, :write, :exclusive], io)

    try do
      check!(io.chmod(path, 0o600), path, "secure acceptance journal")

      check!(
        io.write(file, Jason.encode!(data, pretty: true) <> "\n"),
        path,
        "write acceptance journal"
      )

      check!(io.sync(file), path, "sync acceptance journal")
    after
      check!(io.close(file), path, "close acceptance journal")
    end
  end

  defp sync_directory!(path, io) do
    directory = open!(path, [:raw, :read, :directory], io)

    try do
      check!(io.sync(directory), path, "sync acceptance journal directory")
    after
      check!(io.close(directory), path, "close acceptance journal directory")
    end
  end

  defp open!(path, modes, io) do
    case io.open(path, modes) do
      {:ok, file} ->
        file

      {:error, reason} ->
        raise File.Error, reason: reason, action: "open acceptance journal", path: path
    end
  end

  defp check!(:ok, _, _), do: :ok

  defp check!({:error, reason}, path, action),
    do: raise(File.Error, reason: reason, action: action, path: path)
end

defmodule OpsmaruGatewayAcceptance.Host do
  @moduledoc false
  @behaviour Opsmaru.Incus.Gateway.Host
  alias Opsmaru.Incus.{Error, RequestContext}
  @migration_descriptions ["Creating instance", "Migrating instance", "Transferring snapshot"]

  def fingerprint(der), do: Base.encode16(:crypto.hash(:sha256, der), case: :lower)

  @impl true
  def ready?(config) do
    Agent.get(config.state, fn state ->
      Process.alive?(state.owner) and state.ready and
        System.monotonic_time(:millisecond) - state.last_poll <
          Map.get(config, :freshness_ms, 2_000)
    end)
  end

  @impl true
  def authorize(request, config) do
    certificate = request.peer.certificate
    caller = if is_binary(certificate), do: fingerprint(certificate)
    trusted = Agent.get(config.state, &Map.has_key?(&1.trust, caller))

    result =
      cond do
        request.project not in [nil, config.project] -> {:error, :forbidden}
        request.target != nil or request.all_projects -> {:error, :forbidden}
        not allowed_route?(request, config) -> {:error, :forbidden}
        not trusted -> {:error, :unauthenticated}
        request.operation != nil -> caller_operation(request, caller, config)
        request.project == config.project -> {:ok, {:caller, caller}}
        request.path in ["/", "/1.0", "/1.0/certificates"] -> {:ok, {:caller, caller}}
        true -> {:error, :forbidden}
      end

    record_request(result, request, config)
  end

  # Native global endpoints can ignore project selection. This temporary host
  # admits only the concrete routes needed in its new project and selected pool.
  defp allowed_route?(request, config) do
    path = String.split(request.path, "/") |> Enum.map(&URI.decode/1)
    route_allowed?(request.method, path, request.project == config.project, config)
  end

  defp route_allowed?("GET", ["", path], _, _) when path in ["", "1.0"], do: true
  defp route_allowed?(_, ["", "1.0", "certificates" | _], _, _), do: true

  defp route_allowed?("GET", ["", "1.0", "projects", project], _, config),
    do: project == config.project

  defp route_allowed?("GET", ["", "1.0", "storage-pools", pool], _, config),
    do: pool == Map.get(config, :pool)

  defp route_allowed?("GET", ["", "1.0", "images", image | _], _, config),
    do: image == Map.get(config, :image)

  defp route_allowed?("GET", ["", "1.0", "events"], true, _), do: true
  defp route_allowed?("GET", ["", "1.0", "operations"], true, _), do: true

  defp route_allowed?(method, ["", "1.0", "operations", _ | _], _, _)
       when method in ["GET", "DELETE"], do: true

  defp route_allowed?(method, ["", "1.0", "instances"], true, _) when method in ["GET", "POST"],
    do: true

  defp route_allowed?(method, ["", "1.0", "instances", name | _], true, config)
       when method in ["GET", "POST", "PUT", "PATCH", "DELETE"],
       do: String.starts_with?(name, config.resource_prefix)

  defp route_allowed?(method, ["", "1.0", "profiles"], true, _) when method in ["GET", "POST"],
    do: true

  defp route_allowed?(method, ["", "1.0", "profiles", name], true, config)
       when method in ["GET", "PUT", "PATCH", "DELETE"],
       do: name == "default" or String.starts_with?(name, config.resource_prefix)

  defp route_allowed?(
         method,
         ["", "1.0", "storage-pools", pool, "volumes", "custom" | rest],
         true,
         config
       )
       when method in ["GET", "POST", "PUT", "PATCH", "DELETE"] do
    pool == Map.get(config, :pool) and
      (rest == [] or String.starts_with?(hd(rest), config.resource_prefix))
  end

  defp route_allowed?(_, _, _, _), do: false

  defp record_request({:ok, _} = result, request, config) do
    recorded =
      Agent.get_and_update(config.state, fn state ->
        count = Map.get(state, :request_count, 0)

        if count < 10_000 do
          entry = %{method: request.method, path: request.path, operation: request.operation}

          {true,
           state
           |> Map.put(:request_count, count + 1)
           |> Map.update(:requests, [entry], &[entry | &1])}
        else
          {false, state}
        end
      end)

    if recorded, do: result, else: {:error, :forbidden}
  end

  defp record_request(result, _, _), do: result

  def requests(config), do: Agent.get(config.state, &Enum.reverse(Map.get(&1, :requests, [])))

  defp caller_operation(request, caller, config) do
    if operation_binding(config, request, 500),
      do: {:ok, {:caller, caller}},
      else: {:error, :forbidden}
  end

  @impl true
  def admit_operation_secret(request, config) do
    peer = request.peer.address

    if peer_allowed?(config, peer) and request.target == nil and not request.all_projects do
      case operation_binding(config, request, 500) do
        %{migration: true} ->
          record_request({:ok, {:migration, request.operation, config.project}}, request, config)

        _ ->
          {:error, :forbidden}
      end
    else
      {:error, :forbidden}
    end
  end

  defp peer_allowed?(config, peer),
    do: Agent.get(config.state, &(peer in Map.get(&1, :verified_peers, [])))

  @impl true
  def valid?(request, {:caller, fingerprint}, config) do
    ready?(config) and Agent.get(config.state, &Map.has_key?(&1.trust, fingerprint)) and
      (request.operation == nil or operation_binding(config, request, 0) != nil)
  end

  def valid?(request, {:migration, operation, project}, config) do
    ready?(config) and operation == request.operation and project == config.project and
      peer_allowed?(config, request.peer.address) and
      match?(%{migration: true}, operation_binding(config, request, 0))
  end

  def valid?(_, _, _), do: false

  @impl true
  def identity(_, config), do: {:ok, config.identity}

  @impl true
  def certificates(:create, request, grant, input, config) do
    Agent.get_and_update(config.state, fn state ->
      peer = request.peer.certificate
      supplied = input.body["trust_token"]

      token =
        is_nil(grant) and is_binary(supplied) and is_binary(state.token_digest) and
          Plug.Crypto.secure_compare(:crypto.hash(:sha256, supplied), state.token_digest)

      if peer == state.client_der and (token or match?({:caller, _}, grant)) do
        fingerprint = fingerprint(peer)

        {{:ok, %{}, [{"location", "/1.0/certificates/" <> fingerprint}]},
         %{state | trust: Map.put(state.trust, fingerprint, true), token_digest: nil}}
      else
        {{:error, 403}, state}
      end
    end)
  end

  def certificates(_, _, _, _, _), do: {:error, 501}

  # Only a source-owned poller calls this after verified, project-scoped backend
  # inspection. Secrets are deliberately omitted from the in-memory registry.
  def register(config, operations, now \\ System.monotonic_time(:millisecond)) do
    entries =
      for operation <- operations,
          entry = verified_operation(operation, config, now),
          entry != nil,
          into: %{},
          do: {operation["id"], entry}

    Agent.get_and_update(config.state, fn state ->
      lifetime = RequestContext.check(Map.get(config, :poll_context))
      owner_alive = Process.alive?(state.owner)

      if owner_alive and lifetime == :ok do
        active = Map.reject(state.operations, fn {_, entry} -> entry.expires <= now end)
        {:ok, %{state | operations: Map.merge(active, entries), ready: true, last_poll: now}}
      else
        kind = if owner_alive, do: elem(lifetime, 1), else: :owner_lost
        {{:error, %Error{kind: kind}}, %{state | ready: false, operations: %{}}}
      end
    end)
  end

  defp verified_operation(operation, config, now) do
    id = operation["id"]
    resources = get_in(operation, ["resources", "instances"]) || []

    if is_binary(id) and id != "" and operation["status_code"] in 100..499 and
         resources != [] and Enum.all?(resources, &owned_resource?(&1, config)) do
      metadata = operation["metadata"] || %{}

      migration =
        operation["status_code"] in [100, 101, 102, 103] and operation["class"] == "websocket" and
          operation["description"] in @migration_descriptions and
          Enum.all?(~w(control fs), &(is_binary(metadata[&1]) and metadata[&1] != ""))

      %{
        project: config.project,
        migration: migration,
        expires: now + Map.get(config, :operation_ttl_ms, 5_000)
      }
    end
  end

  defp owned_resource?(resource, config) when is_binary(resource) do
    uri = URI.parse(resource)
    query = URI.decode_query(uri.query || "")

    case String.split(uri.path || "", "/") do
      ["", "1.0", "instances", name | _] ->
        String.starts_with?(URI.decode(name), config.resource_prefix) and
          query["project"] in [nil, config.project]

      _ ->
        false
    end
  end

  defp owned_resource?(_, _), do: false

  defp operation_binding(config, request, remaining) do
    entry = Agent.get(config.state, &Map.get(&1.operations, request.operation))

    cond do
      request.project not in [nil, config.project] ->
        nil

      entry != nil and entry.project == config.project and
          entry.expires > System.monotonic_time(:millisecond) ->
        entry

      remaining <= 0 ->
        nil

      true ->
        Process.sleep(10)
        operation_binding(config, request, remaining - 10)
    end
  end
end

defmodule OpsmaruGatewayAcceptance.Router do
  @moduledoc false
  @behaviour Plug
  alias Opsmaru.Incus.Gateway.Plug, as: GatewayPlug
  def init(gateway), do: gateway
  def call(conn, gateway), do: GatewayPlug.call(conn, {:static, gateway})
end

defmodule OpsmaruGatewayAcceptance do
  @moduledoc "Explicit, isolated acceptance host runtime; never starts on dependency load."
  alias Opsmaru.Incus
  alias Opsmaru.Incus.{Connection, Context, Error, Gateway, Model}
  alias Opsmaru.Incus.Gateway.Admission
  alias OpsmaruGatewayAcceptance.Host
  @sides ~w(source target)
  @protocols ~w(discovery enrollment http binary exec console events sftp nbd denial interruption)
  @migration_cases for action <- ~w(copy move),
                       kind <- ~w(instance snapshot),
                       mode <- ~w(relay pull push),
                       side <- @sides,
                       do: Enum.join([action, kind, mode, side], "/")
  @cases @protocols ++ @migration_cases
  @accepted_native_limitations for mode <- ~w(relay pull push),
                                   side <- @sides,
                                   do: Enum.join(["move", "snapshot", mode, side], "/")

  def required_cases, do: @cases
  def accepted_native_limitations, do: @accepted_native_limitations

  def evidence_complete?(cases) do
    Enum.all?(@cases, fn name ->
      cases[name] == "passed" or
        (name in @accepted_native_limitations and cases[name] == "native_limitation")
    end)
  end

  def validate!(config) do
    require!(
      is_map(config) and config["allow_namespaced_mutations"] == true,
      "explicit mutation opt-in required"
    )

    require!(config["expected_version"] == "7.0.1", "pinned version required")

    require!(
      absolute?(config["report"]) and not File.exists?(config["report"]),
      "unused absolute report path required"
    )

    require!(
      absolute?(config["state_directory"]) and not File.exists?(config["state_directory"]),
      "new absolute private state directory required"
    )

    for side <- @sides, do: validate_side!(Map.fetch!(config, side))

    require!(
      config["source"]["network"] == config["target"]["network"],
      "native CLI copies require matching network names"
    )

    require!(
      config["source"]["project"] != config["target"]["project"],
      "distinct isolated projects required"
    )

    config
  end

  defp validate_side!(side) do
    require!(
      is_binary(side["project"]) and
        Regex.match?(~r/\Aopsmaru-acceptance-gateway-[a-z0-9-]+\z/, side["project"]),
      "isolated project namespace required"
    )

    require!(
      is_binary(side["image"]) and Regex.match?(~r/\A[0-9a-f]{64}\z/, side["image"]),
      "explicit image fingerprint required"
    )

    require!(is_binary(side["pool"]) and side["pool"] != "", "explicit pool required")
    require!(is_binary(side["network"]) and side["network"] != "", "explicit network required")
    validate_identity!(side["expected_identity"] || %{})
    validate_backend!(side["backend"] || %{})
    validate_gateway!(side["gateway"] || %{})
  end

  defp validate_identity!(expected) do
    require!(
      is_binary(expected["server_name"]) and expected["server_name"] != "" and
        is_binary(expected["certificate_sha256"]) and
        Regex.match?(~r/\A[0-9a-f]{64}\z/, expected["certificate_sha256"]),
      "explicit verified backend identity required"
    )
  end

  defp validate_backend!(backend) do
    require!(
      (absolute?(backend["socket"]) and not Map.has_key?(backend, "https")) or
        (is_binary(backend["https"]) and not Map.has_key?(backend, "socket")),
      "one explicit backend transport required"
    )
  end

  defp validate_gateway!(gateway) do
    uri = URI.parse(gateway["https"] || "")

    require!(
      uri.scheme == "https" and is_binary(uri.host) and uri.port in 1..65_535 and
        uri.path in [nil, "", "/"] and uri.query == nil and uri.fragment == nil and
        uri.userinfo == nil,
      "explicit gateway HTTPS origin required"
    )

    require!(ip?(gateway["bind_ip"]), "explicit bind address required")

    require!(
      is_list(gateway["allowed_operation_peers"]) and gateway["allowed_operation_peers"] != [] and
        Enum.all?(gateway["allowed_operation_peers"], &ip?/1),
      "explicit operation peers required"
    )

    for field <- ~w(server_certificate server_key client_certificate client_key client_ca) do
      require!(
        absolute?(gateway[field]) and File.regular?(gateway[field]),
        "gateway credential references required"
      )
    end
  end

  def run(config, scenario) when is_function(scenario, 1) do
    validate!(config)
    File.mkdir!(config["state_directory"])
    File.chmod!(config["state_directory"], 0o700)
    {:ok, journal} = Agent.start_link(fn -> initial_report(config) end)
    context = %{config: config, journal: journal, runtime: config["state_directory"], sides: %{}}

    try do
      create_report!(config["report"], Agent.get(journal, & &1))
      run_reported(context, scenario)
    after
      stop_local(journal)
    end
  end

  defp run_reported(context, scenario) do
    config = context.config

    try do
      start_runtime!()
      {clients, verified_pools, verified_networks} = inspect_backends!(context)
      nonce = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
      prefix = "gw-" <> binary_part(nonce, 0, 12) <> "-"

      context =
        Map.merge(context, %{
          clients: clients,
          verified_pools: verified_pools,
          verified_networks: verified_networks,
          marker: nonce,
          resource_prefix: prefix
        })

      journal_update(
        context,
        &Map.merge(&1, %{
          "run_marker" => nonce,
          "resource_prefix" => prefix,
          "backend_identities" =>
            Map.new(@sides, fn side -> {side, config[side]["expected_identity"]} end)
        })
      )

      create_projects!(context)
      with_hosts(context, scenario)
    rescue
      error ->
        record_failure(context, Atom.to_string(error.__struct__))
        reraise error, __STACKTRACE__
    catch
      kind, reason ->
        record_failure(context, Atom.to_string(kind))
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp start_runtime! do
    # Explicit acceptance-host startup only. Requiring this file, loading the
    # library and rejecting unapproved configuration never starts these apps.
    for application <- [:ssl, :plug_cowboy] do
      {:ok, _} = Application.ensure_all_started(application)
    end
  end

  defp record_failure(context, kind) do
    quietly(fn ->
      journal_update(
        context,
        &Map.merge(&1, %{"phase" => "failed-resources-retained", "failure" => kind})
      )
    end)
  end

  defp initial_report(config),
    do: %{
      "schema" => "opsmaru-incus-gateway-live/v1",
      "evidence" => "real-incus-gateway",
      "phase" => "intent",
      "config_fingerprint" =>
        Base.encode16(:crypto.hash(:sha256, :erlang.term_to_binary(config)), case: :lower),
      "host_source_sha256" =>
        Base.encode16(:crypto.hash(:sha256, File.read!(__ENV__.file)), case: :lower),
      "projects" => Map.new(@sides, &{&1, config[&1]["project"]}),
      "steps" => [],
      "details" => [],
      "cases" => Map.new(@cases, &{&1, "unrun"}),
      "typed_client_coverage" => "unchanged",
      "installed_host" => "unrun",
      "macus_hardware" => "unrun"
    }

  defp inspect_backends!(context) do
    inspected =
      for side <- @sides, into: %{} do
        config = context.config[side]
        connection = backend_connection(config["backend"])

        binding =
          Context.new!(
            owner: :gateway_acceptance,
            identity: :verified_operator,
            ready?: fn -> true end
          )

        {:ok, client} = Incus.connect(connection, binding)
        verify_identity!(client, config["expected_identity"], context.config["expected_version"])

        {:error, %Error{http_status: 404}} =
          Incus.call(client, "GetProject", %{"name" => config["project"]})

        {:ok, image} = Incus.call(client, "GetImage", %{"fingerprint" => config["image"]})

        require!(
          image.metadata.data["type"] == "container",
          "acceptance image must be a container"
        )

        {:ok, pool} = Incus.call(client, "GetStoragePool", %{"name" => config["pool"]})
        data = pool.metadata.data
        require!(data["name"] == config["pool"], "acceptance pool identity mismatch")
        require!(data["status"] == "Created", "acceptance pool must be ready")
        driver = data["driver"]

        require!(
          is_binary(driver) and Regex.match?(~r/\A[a-z][a-z0-9_-]{0,63}\z/, driver),
          "acceptance pool driver unavailable"
        )

        network = inspect_network!(client, config["network"])
        {side, {client, %{name: data["name"], driver: driver}, network}}
      end

    journal_update(context, &Map.put(&1, "phase", "fresh-projects-and-backends-verified"))
    clients = Map.new(inspected, fn {side, {client, _, _}} -> {side, client} end)
    verified_pools = Map.new(inspected, fn {side, {_, pool, _}} -> {side, pool} end)
    verified_networks = Map.new(inspected, fn {side, {_, _, network}} -> {side, network} end)
    {clients, verified_pools, verified_networks}
  end

  defp inspect_network!(client, name) do
    case Incus.call(client, "GetNetwork", %{"name" => name}) do
      {:ok, response} ->
        network = response.metadata.data
        require!(network["name"] == name, "acceptance network identity mismatch")
        require!(network["status"] == "Created", "acceptance network must be ready")
        require!(network["managed"] === true, "acceptance network must be managed")
        %{name: name, managed: true, status: "Created"}

      {:error, _} ->
        raise ArgumentError, "acceptance network unavailable"
    end
  end

  defp backend_connection(%{"socket" => socket}) do
    Connection.unix!(socket, owner: :gateway_acceptance, stream_timeout: 120_000)
  end

  defp backend_connection(config) do
    pin = certificate_pin(File.read!(config["server_certificate"]))

    Connection.https!(config["https"],
      owner: :gateway_acceptance,
      stream_timeout: 120_000,
      tls: [
        fingerprint: pin,
        certfile: config["client_certificate"],
        keyfile: config["client_key"]
      ]
    )
  end

  defp verify_identity!(client, expected, version) do
    environment = client.server.environment

    require!(
      environment["server_version"] == version and
        environment["server_name"] == expected["server_name"] and
        certificate_pin(environment["certificate"]) == expected["certificate_sha256"],
      "backend identity mismatch"
    )
  end

  defp create_projects!(context) do
    for side <- @sides do
      client = context.clients[side]
      project = context.config[side]["project"]

      step(context, "create-project/" <> side, fn ->
        Incus.call(client, "CreateProject", %{},
          body: %{
            "name" => project,
            "description" => "Opsmaru gateway acceptance " <> context.marker,
            "config" => %{
              "features.images" => "false",
              "features.networks" => "false",
              "features.profiles" => "true",
              "features.storage.volumes" => "true"
            }
          }
        )
      end)

      verify_project!(client, project, context.marker)
    end
  end

  defp verify_project!(client, project, marker) do
    {:ok, response} = Incus.call(client, "GetProject", %{"name" => project})

    require!(
      response.metadata.data["description"] == "Opsmaru gateway acceptance " <> marker,
      "project marker mismatch"
    )
  end

  defp with_hosts(context, scenario) do
    {:ok, supervisor} = Task.Supervisor.start_link()
    Process.put({__MODULE__, :hosts}, [])

    try do
      sides = for side <- @sides, into: %{}, do: {side, start_host!(context, side, supervisor)}
      cli_directory = Path.join(context.runtime, "cli")
      File.mkdir!(cli_directory)
      File.chmod!(cli_directory, 0o700)
      context = context |> Map.put(:sides, sides) |> Map.put(:incus_conf, cli_directory)

      for {_, side} <- sides,
          do:
            await_host_ready!(
              side.host,
              System.monotonic_time(:millisecond) + side.host.freshness_ms
            )

      journal_update(context, &Map.put(&1, "phase", "host-mounted-protocols-unrun"))
      scenario.(context)
      report = Agent.get(context.journal, & &1)
      cases = report["cases"]

      phase =
        cond do
          not evidence_complete?(cases) ->
            "partial-resources-retained"

          report["cleanup"] == "verified-projects-absent" and
              Enum.any?(cases, fn {_, result} -> result == "native_limitation" end) ->
            "passed-with-native-limitations-and-cleaned"

          report["cleanup"] == "verified-projects-absent" ->
            "passed-and-cleaned"

          Enum.any?(cases, fn {_, result} -> result == "native_limitation" end) ->
            "passed-with-native-limitations-resources-retained"

          true ->
            "passed-resources-retained"
        end

      journal_update(context, &Map.put(&1, "phase", phase))
      Agent.get(context.journal, & &1)
    after
      # All listeners/tasks are local acceptance resources. Backend projects and
      # operations are retained on failure; nothing here remotely cancels them.
      stop_local(supervisor)

      for resource <- Process.delete({__MODULE__, :hosts}) || [] do
        send(resource.watcher, :stop)

        receive do
          {:host_stopped, ref} when ref == resource.ref -> :ok
        after
          5_000 ->
            stop_listener(resource.ref)
            stop_local(resource.state)
            stop_local(resource.admission)
        end
      end
    end
  end

  defp start_host!(context, side, supervisor) do
    spec = context.config[side]
    gateway_config = spec["gateway"]
    client_der = certificate_der(File.read!(gateway_config["client_certificate"]))

    token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    state = %{
      owner: self(),
      trust: %{Host.fingerprint(client_der) => true},
      client_der: client_der,
      token_digest: :crypto.hash(:sha256, token),
      verified_peers: [],
      operations: %{},
      ready: false,
      last_poll: 0
    }

    {:ok, state_pid} = Agent.start_link(fn -> state end)
    {:ok, admission} = Admission.start_link(max_exchanges: 64)
    connection = context.clients[side].connection
    uri = URI.parse(gateway_config["https"])

    host =
      Map.merge(poll_budgets(connection), %{
        state: state_pid,
        project: spec["project"],
        resource_prefix: context.resource_prefix,
        pool: spec["pool"],
        image: spec["image"],
        allowed_peers: Enum.map(gateway_config["allowed_operation_peers"], &parse_ip/1),
        identity: %{
          origin: gateway_config["https"],
          addresses: [uri.authority],
          certificate: File.read!(gateway_config["server_certificate"]),
          connection: connection,
          api_extensions: context.clients[side].server.api_extensions
        }
      })

    gateway =
      Gateway.new!(
        connection: connection,
        host: Host,
        host_config: host,
        admission: admission,
        callback_timeout: 1_000,
        recheck_interval: 5_000,
        max_lifetime: 1_800_000,
        idle_timeout: 120_000,
        max_request_bytes: 1_073_741_824,
        max_response_bytes: 1_073_741_824
      )

    ref = {__MODULE__, make_ref()}

    dispatch =
      :cowboy_router.compile([
        {:_,
         [
           {:_, Opsmaru.Incus.Gateway.CowboyHandler,
            %{
              gateway: gateway,
              fallback: {Plug.Cowboy.Handler, {OpsmaruGatewayAcceptance.Router, gateway}}
            }}
         ]}
      ])

    socket_options = [
      ip: parse_ip(gateway_config["bind_ip"]),
      port: uri.port,
      certfile: String.to_charlist(gateway_config["server_certificate"]),
      keyfile: String.to_charlist(gateway_config["server_key"]),
      cacerts: Connection.ca_certificates(gateway_config["client_ca"]),
      verify: :verify_peer,
      fail_if_no_peer_cert: false,
      alpn_preferred_protocols: ["http/1.1"],
      versions: [:"tlsv1.3", :"tlsv1.2"]
    ]

    owner = self()

    watcher =
      spawn(fn ->
        monitor = Process.monitor(owner)

        receive do
          {:DOWN, ^monitor, :process, ^owner, _} -> :ok
          :stop -> :ok
        end

        stop_listener(ref)
        stop_local(state_pid)
        stop_local(admission)
        send(owner, {:host_stopped, ref})
      end)

    Process.put({__MODULE__, :hosts}, [
      %{ref: ref, watcher: watcher, state: state_pid, admission: admission}
      | Process.get({__MODULE__, :hosts}, [])
    ])

    {:ok, _} =
      :cowboy.start_tls(ref, %{socket_opts: socket_options}, %{env: %{dispatch: dispatch}})

    {:ok, _poller} = Task.Supervisor.start_child(supervisor, fn -> poll(context, side, host) end)
    client_directory = Path.join(context.runtime, side)
    File.mkdir!(client_directory)
    File.chmod!(client_directory, 0o700)

    %{
      gateway: gateway,
      host: host,
      origin: gateway_config["https"],
      client: Incus.project(context.clients[side], spec["project"]),
      incus_conf: client_directory,
      listener: ref,
      token: token
    }
  end

  defp await_host_ready!(host, deadline) do
    cond do
      Host.ready?(host) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        raise "acceptance host policy is not ready"

      true ->
        Process.sleep(10)
        await_host_ready!(host, deadline)
    end
  end

  defp stop_listener(ref), do: quietly(fn -> :cowboy.stop_listener(ref) end)
  defp stop_local(pid), do: quietly(fn -> GenServer.stop(pid, :normal, 1_000) end)

  defp quietly(fun) do
    fun.()
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp poll(context, side, host) do
    if poll_once(context, side, host) == :continue do
      Process.sleep(host.poll_interval_ms)
      poll(context, side, host)
    end
  end

  @doc false
  def poll_budgets(%Connection{timeout: timeout}) do
    # One cycle has two sequential, individually bounded metadata requests.
    # Allow a 100ms cadence plus bounded scheduling slack beyond both deadlines.
    %{
      freshness_ms: 2 * timeout + 2_000,
      operation_ttl_ms: 2 * timeout + 2_000,
      poll_interval_ms: 100
    }
  end

  @doc false
  def poll_once(context, side, host) do
    started = System.monotonic_time(:millisecond)

    client = Incus.project(context.clients[side], host.project)
    owner = poll_result(fn -> poll_guard(client, host) end)

    if owner == :ok do
      project = poll_result(fn -> poll_project(client, host.project, context.marker) end)

      case project do
        :ok ->
          poll_operations(context, side, host, client, started)

        {:error, error} ->
          poll_failed(context, side, host, client, "project", error, started)
      end
    else
      {:error, error} = owner
      poll_failed(context, side, host, client, "owner", error, started)
    end
  end

  defp poll_guard(client, host) do
    if Agent.get(host.state, &Process.alive?(&1.owner)) do
      case Context.authorize(client.context, client.connection) do
        :ok -> :ok
        {:error, kind} -> {:error, %Error{kind: kind}}
      end
    else
      {:error, %Error{kind: :owner_lost}}
    end
  end

  defp poll_project(client, project, marker) do
    case Incus.call(client, "GetProject", %{"name" => project}) do
      {:ok, response} ->
        if response.metadata.data["description"] == "Opsmaru gateway acceptance " <> marker,
          do: :ok,
          else: {:error, %Error{kind: :project_marker_mismatch}}

      {:error, error} ->
        {:error, error}
    end
  end

  defp poll_operations(context, side, host, client, started) do
    result =
      poll_result(fn ->
        with :ok <- poll_guard(client, host),
             {:ok, response} <- Incus.call(client, "GetOperations", %{}),
             operations = Enum.map(response.metadata, &Model.encode/1),
             :ok <- poll_guard(client, host) do
          Host.register(
            Map.put(host, :poll_context, client.connection.request_context),
            operations
          )
        end
      end)

    case result do
      :ok ->
        :continue

      {:error, error} ->
        poll_failed(context, side, host, client, "operations", error, started)
    end
  end

  defp poll_failed(context, side, host, client, stage, error, started) do
    error =
      case poll_result(fn -> poll_guard(client, host) end) do
        :ok -> error
        {:error, revoked} -> revoked
      end

    retained = poll_failure(context, side, host, stage, error, started)

    cond do
      retained ->
        :continue

      transient_poll_error?(error) ->
        :stop

      stage == "operations" and
          error.kind not in [
            :poll_exception,
            :poll_exit,
            :owner_lost,
            :canceled,
            :host_not_ready,
            :owner_mismatch
          ] ->
        :continue

      true ->
        :stop
    end
  end

  defp transient_poll_error?(%Error{kind: kind, http_status: nil}),
    do: kind in [:connection, :response_closed]

  defp transient_poll_error?(_), do: false

  defp poll_result(fun) do
    fun.()
  rescue
    _ -> {:error, %Error{kind: :poll_exception}}
  catch
    _, _ -> {:error, %Error{kind: :poll_exit}}
  end

  @poll_error_kinds ~w(native connection response_closed cache_expired deadline request response response_limit invalid_response invalid_envelope invalid_model invalid_metadata invalid_response_model unsupported_extension forbidden unauthorized not_ready host_not_ready owner_mismatch canceled owner_lost project_marker_mismatch poll_exception poll_exit)a
  defp poll_failure(context, side, host, stage, error, started) do
    transient = transient_poll_error?(error)
    now = System.monotonic_time(:millisecond)

    {record?, retained, kind, remaining} =
      Agent.get_and_update(
        host.state,
        &poll_failure_state(&1, host, error.kind, transient, now),
        1_000
      )

    if record? do
      kind = if kind in @poll_error_kinds, do: Atom.to_string(kind), else: "poll_error"

      status = if error.http_status in 100..599, do: error.http_status

      evidence = %{
        "error_kind" => kind,
        "http_status" => status,
        "elapsed_ms" => max(0, System.monotonic_time(:millisecond) - started),
        "proof" => %{
          "stage" => stage,
          "remaining_cache_ms" => remaining,
          "retained_authority" => retained
        }
      }

      record_poll_diagnostic(context, side, evidence, retained)
    end

    retained
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp poll_failure_state(state, host, kind, transient, now) do
    freshness = Map.get(host, :freshness_ms, 2_000)

    remaining =
      if state.ready, do: min(freshness, max(0, freshness - (now - state.last_poll))), else: 0

    retained = transient and state.ready and remaining > 0
    kind = if transient and state.ready and remaining == 0, do: :cache_expired, else: kind
    failures = Map.get(state, :poll_transient_failure_count, 0)

    updated =
      if retained,
        do: Map.put(state, :poll_transient_failure_count, min(15, failures + 1)),
        else: %{state | ready: false, operations: %{}}

    {{not retained or failures < 15, retained, kind, remaining}, updated}
  end

  defp record_poll_diagnostic(context, side, evidence, true),
    do: record_detail(context, "poll-transient/" <> side, evidence)

  defp record_poll_diagnostic(context, side, evidence, false) do
    # Reserve one replaceable decisive slot even after fifteen transient entries.
    # Only fixed safe fields produced above enter this bounded local record.
    label = "poll-decisive/" <> side
    entry = %{"step" => label, "evidence" => evidence}

    journal_update(
      context,
      &Map.update!(&1, "details", fn details -> replace_poll_diagnostic(details, label, entry) end)
    )
  end

  defp replace_poll_diagnostic(details, label, entry) do
    case Enum.find_index(details, &(&1["step"] == label)) do
      nil -> details ++ [entry]
      index -> List.replace_at(details, index, entry)
    end
  end

  def step(context, label, fun) when is_binary(label) and is_function(fun, 0) do
    journal_update(
      context,
      &Map.update!(&1, "steps", fn steps ->
        steps ++ [%{"step" => label, "outcome" => "pending"}]
      end)
    )

    result = fun.()
    summary = summary(result)

    journal_update(
      context,
      &Map.update!(&1, "steps", fn steps ->
        List.update_at(steps, -1, fn entry -> Map.merge(entry, summary) end)
      end)
    )

    require!(summary["outcome"] == "passed", "acceptance step failed; resources retained")
    result
  end

  def record_case(context, name, outcome)
      when name in @cases and outcome in ["passed", "native_limitation", "failed", "unrun"] do
    journal_update(context, &put_in(&1, ["cases", name], outcome))
  end

  def mark_cleaned(context) do
    require!(
      evidence_complete?(Agent.get(context.journal, & &1["cases"])),
      "partial acceptance cannot be marked cleaned"
    )

    for side <- @sides do
      {:error, %Error{http_status: 404}} =
        Incus.call(context.clients[side], "GetProject", %{
          "name" => context.config[side]["project"]
        })
    end

    journal_update(context, &Map.put(&1, "cleanup", "verified-projects-absent"))
    :ok
  end

  def clear_verified_operation_peers(context, receiver) when receiver in @sides do
    Agent.update(context.sides[receiver].host.state, &Map.put(&1, :verified_peers, []))

    record_detail(context, "operation-peer-unverified/" <> receiver, %{
      "status" => "unverified",
      "proof" => %{"receiver" => receiver}
    })

    :ok
  end

  # Compatibility helper for fixtures that deliberately verify the same peer
  # for both receivers. Real daemon acceptance uses the per-receiver overload.
  def set_verified_operation_peers(context, addresses, nonce_sha256) do
    for side <- @sides, do: set_verified_operation_peers(context, side, addresses, nonce_sha256)
    :ok
  end

  def set_verified_operation_peers(context, receiver, addresses, nonce_sha256)
      when receiver in @sides do
    require!(
      is_list(addresses) and addresses != [] and Enum.all?(addresses, &ip?/1),
      "verified literal peer addresses required"
    )

    require!(
      is_binary(nonce_sha256) and Regex.match?(~r/\A[0-9a-f]{64}\z/, nonce_sha256),
      "verified probe nonce digest required"
    )

    record_detail(context, "verified-operation-peers/" <> receiver, %{
      "proof" => %{"receiver" => receiver, "peers" => addresses, "nonce_sha256" => nonce_sha256}
    })

    peers = Enum.map(addresses, &parse_ip/1)
    Agent.update(context.sides[receiver].host.state, &Map.put(&1, :verified_peers, peers))
    :ok
  end

  @detail_fields ~w(operation operation_id operation_ids status outcome http_status error_code error_kind error_reference sha256 expected_sha256 payload_sha256 bytes byte_count stdout_bytes stderr_bytes exit_status frames close_code elapsed_ms accepted completed retained_source initial_writes final_writes request_count delete_count gateway_posts gateway_deletes native_error native_status tool_sha256 source_revision cli_sha256 driver_sha256 protocol scenario proof hashes count)
  def record_detail(context, label, evidence) when is_binary(label) and is_map(evidence) do
    require!(Map.keys(evidence) -- @detail_fields == [], "undeclared acceptance evidence fields")
    encoded = Jason.encode!(evidence)

    require!(
      byte_size(encoded) <= 16_384 and safe_evidence?(evidence) and
        not Regex.match?(~r/BEGIN[^\n]*PRIVATE KEY/i, encoded) and
        not String.contains?(String.downcase(encoded), [
          "secret=",
          "trust_token",
          "authorization",
          "begin private key"
        ]),
      "acceptance evidence must be bounded and redacted"
    )

    journal_update(
      context,
      &Map.update!(&1, "details", fn details ->
        details ++ [%{"step" => label, "evidence" => evidence}]
      end)
    )
  end

  @private_evidence_fields ~w(client_certificate client_key server_certificate server_key authorization password token trust_token secret secrets headers input raw_stdout)
  defp safe_evidence?(value) when is_map(value) do
    Enum.all?(value, fn {key, item} ->
      key not in @private_evidence_fields and safe_evidence?(item)
    end)
  end

  defp safe_evidence?(value) when is_list(value), do: Enum.all?(value, &safe_evidence?/1)
  defp safe_evidence?(_), do: true

  defp summary({:ok, %Opsmaru.Incus.Response{} = response}),
    do: %{"outcome" => "passed", "operation" => response.operation}

  defp summary({:ok, _}), do: %{"outcome" => "passed"}
  defp summary(:ok), do: %{"outcome" => "passed"}

  defp summary({:error, %Error{} = error}),
    do: %{
      "outcome" => "failed",
      "operation" => error.operation,
      "http_status" => error.http_status
    }

  defp summary(_), do: %{"outcome" => "failed"}

  defp journal_update(context, fun) do
    result =
      Agent.get_and_update(context.journal, fn current ->
        try do
          updated = fun.(current)
          # A trusted in-process fixture seam; input JSON never selects journal I/O.
          io = Map.get(context, :journal_io, OpsmaruGatewayAcceptance.Journal.FileIO)
          OpsmaruGatewayAcceptance.Journal.replace!(context.config["report"], updated, io)
          {:ok, updated}
        rescue
          error -> {{:error, error, __STACKTRACE__}, current}
        end
      end)

    case result do
      :ok -> :ok
      {:error, error, stacktrace} -> reraise error, stacktrace
    end
  end

  defp create_report!(path, data) do
    OpsmaruGatewayAcceptance.Journal.create!(path, data)
  end

  def certificate_pin(pem), do: Host.fingerprint(certificate_der(pem))

  defp certificate_der(pem) do
    [{:Certificate, der, :not_encrypted}] = :public_key.pem_decode(pem)
    der
  end

  defp absolute?(value), do: is_binary(value) and Path.type(value) == :absolute

  defp ip?(value),
    do: is_binary(value) and match?({:ok, _}, :inet.parse_address(String.to_charlist(value)))

  defp parse_ip(value), do: value |> String.to_charlist() |> :inet.parse_address() |> elem(1)
  defp require!(true, _), do: :ok
  defp require!(_, message), do: raise(ArgumentError, message)
end
