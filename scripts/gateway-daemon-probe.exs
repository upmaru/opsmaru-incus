# Source-owned negative migration probe. Requiring this file performs no I/O.
defmodule OpsmaruGatewayDaemonProbe.Beacon do
  @moduledoc false
  use GenServer
  alias Opsmaru.Incus.Connection

  def start_link(gateway, path, secret_digest),
    do: GenServer.start_link(__MODULE__, {gateway, path, secret_digest})

  def endpoint(pid), do: GenServer.call(pid, :endpoint)
  def proof(pid), do: GenServer.call(pid, :proof)

  @impl true
  def init({gateway, path, secret_digest}) do
    {:ok, _} = Application.ensure_all_started(:ssl)
    {:ok, bind} = :inet.parse_address(String.to_charlist(gateway["bind_ip"]))

    {:ok, listener} =
      :ssl.listen(0, [
        :binary,
        ip: bind,
        active: false,
        reuseaddr: true,
        certfile: String.to_charlist(gateway["server_certificate"]),
        keyfile: String.to_charlist(gateway["server_key"]),
        versions: [:"tlsv1.3", :"tlsv1.2"],
        alpn_preferred_protocols: ["http/1.1"],
        verify: :verify_peer,
        fail_if_no_peer_cert: false,
        cacerts: Connection.ca_certificates(gateway["client_ca"])
      ])

    {:ok, {_, port}} = :ssl.sockname(listener)
    owner = self()
    worker = spawn_link(fn -> accept(listener, owner, path, secret_digest) end)
    uri = URI.parse(gateway["https"])
    origin = URI.to_string(%{uri | authority: nil, port: port, path: nil})
    {:ok, %{listener: listener, worker: worker, origin: origin, proof: nil}}
  end

  @impl true
  def handle_call(:endpoint, _, state), do: {:reply, state.origin, state}
  def handle_call(:proof, _, state), do: {:reply, state.proof, state}

  def handle_call({:verified, peer}, _, state) do
    proof = state.proof || %{peer: peer}
    {:reply, :ok, %{state | proof: proof}}
  end

  @impl true
  def terminate(_, state) do
    :ssl.close(state.listener)
    Process.exit(state.worker, :shutdown)
  end

  defp accept(listener, owner, path, digest) do
    case :ssl.transport_accept(listener, 1_000) do
      {:ok, socket} ->
        serve(socket, owner, path, digest)
        accept(listener, owner, path, digest)

      {:error, :timeout} ->
        accept(listener, owner, path, digest)

      {:error, _} ->
        :ok
    end
  end

  defp serve(socket, owner, path, digest) do
    with {:ok, socket} <- :ssl.handshake(socket, 3_000),
         {:ok, head} <- read_head(socket, "", System.monotonic_time(:millisecond) + 3_000),
         true <- valid_request?(head, path, digest),
         {:ok, {peer, _}} <- :ssl.peername(socket) do
      # Synchronous proof storage precedes the negative response, so the daemon's
      # terminal operation cannot race its verified peer observation.
      :ok = GenServer.call(owner, {:verified, peer})
    end

    :ssl.send(socket, "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  after
    :ssl.close(socket)
  end

  defp read_head(socket, bytes, deadline) do
    cond do
      byte_size(bytes) > 8_192 ->
        {:error, :limit}

      String.contains?(bytes, "\r\n\r\n") ->
        {:ok, bytes}

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :timeout}

      true ->
        case :ssl.recv(socket, 0, max(1, deadline - System.monotonic_time(:millisecond))) do
          {:ok, data} -> read_head(socket, bytes <> data, deadline)
          _ -> {:error, :closed}
        end
    end
  end

  defp valid_request?(head, path, digest) do
    [line | _] = String.split(head, "\r\n")

    case String.split(line, " ") do
      ["GET", target, "HTTP/1.1"] -> valid_target?(URI.parse(target), path, digest)
      _ -> false
    end
  rescue
    _ -> false
  end

  defp valid_target?(uri, path, digest) do
    values = URI.query_decoder(uri.query || "") |> Enum.to_list()

    case values do
      [{"secret", secret}] ->
        uri.path == path and uri.scheme == nil and uri.host == nil and
          Plug.Crypto.secure_compare(:crypto.hash(:sha256, secret), digest)

      _ ->
        false
    end
  end
end

defmodule OpsmaruGatewayDaemonProbe do
  @moduledoc "Verify each actual backend daemon's peer using a scoped negative volume migration."
  alias Opsmaru.Incus
  alias Opsmaru.Incus.{Error, Model, Operation}
  alias OpsmaruGatewayAcceptance, as: Runner
  alias OpsmaruGatewayDaemonProbe.Beacon

  def verify_and_activate(context) do
    true = context.config["allow_namespaced_mutations"] == true
    true = is_binary(context.marker) and context.marker != ""
    true = String.starts_with?(context.resource_prefix, "gw-")
    _ = timeout(context)

    for side <- ["source", "target"] do
      true =
        Regex.match?(
          ~r/\Aopsmaru-acceptance-gateway-[a-z0-9-]+\z/,
          context.config[side]["project"]
        )
    end

    for receiver <- ["source", "target"],
        do: Runner.clear_verified_operation_peers(context, receiver)

    Map.new([{"source", "target"}, {"target", "source"}], fn {receiver, actor} ->
      {receiver, verify_receiver(context, receiver, actor)}
    end)
  end

  defp verify_receiver(context, receiver, actor) do
    client = context.sides[actor].client
    spec = context.config[actor]
    nonce = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    secret = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    digest = Base.encode16(:crypto.hash(:sha256, nonce), case: :lower)

    name =
      context.resource_prefix <> "daemon-probe-" <> receiver <> "-" <> binary_part(nonce, 0, 8)

    verify_project!(context, actor, client)
    {:error, %Error{http_status: 404}} = volume(client, spec["pool"], name)
    path = "/1.0/operations/" <> nonce <> "/websocket"
    gateway = context.config[receiver]["gateway"]
    {:ok, beacon} = Beacon.start_link(gateway, path, :crypto.hash(:sha256, secret))

    try do
      body = %{
        name: name,
        type: "custom",
        content_type: "filesystem",
        description: context.marker,
        source: %{
          type: "migration",
          mode: "pull",
          certificate: File.read!(gateway["server_certificate"]),
          operation: Beacon.endpoint(beacon) <> "/1.0/operations/" <> nonce,
          secrets: %{control: secret, fs: secret},
          volume_only: true
        }
      }

      Runner.record_detail(context, "daemon-probe-intent/" <> receiver, %{
        "proof" => %{
          "actor" => actor,
          "receiver" => receiver,
          "project" => spec["project"],
          "pool" => spec["pool"],
          "volume" => name,
          "nonce_sha256" => digest
        }
      })

      # Revalidate immediately before the only mutation; project feature changes
      # must never make this request fall back to the default volume namespace.
      verify_project!(context, actor, client)

      result =
        Incus.raw_query(
          client,
          "POST",
          "/1.0/storage-pools/" <> escape(spec["pool"]) <> "/volumes/custom",
          body: body
        )

      reconcile(context, receiver, actor, name, digest, beacon, result)
    after
      GenServer.stop(beacon)
    end
  end

  defp verify_project!(context, actor, client) do
    project = context.config[actor]["project"]
    true = client.connection.project == project
    {:ok, response} = Incus.call(context.clients[actor], "GetProject", %{"name" => project})
    data = response.metadata.data
    true = data["description"] == "Opsmaru gateway acceptance " <> context.marker
    true = data["config"]["features.storage.volumes"] == "true"
  end

  defp reconcile(context, receiver, actor, name, digest, beacon, {:ok, response}) do
    case Operation.from_response(context.sides[actor].client, response) do
      {:ok, operation} ->
        Runner.record_detail(context, "daemon-probe-accepted/" <> receiver, %{
          "operation_id" => operation.url,
          "accepted" => true,
          "proof" => %{"actor" => actor, "receiver" => receiver, "volume" => name}
        })

        terminal = Operation.wait(operation, timeout: timeout(context), poll_interval: 50)
        proof = Beacon.proof(beacon)
        residual = retained_volume(context, actor, name)
        verified = expected_failure?(terminal) and proof != nil and residual != :unknown

        record_result(context, receiver, actor, %{
          operation: operation.url,
          digest: digest,
          proof: proof,
          residual: residual,
          verified: verified,
          terminal: terminal_status(terminal),
          terminal_code: terminal_code(terminal)
        })

        if verified do
          peer = proof.peer |> :inet.ntoa() |> to_string()
          :ok = Runner.set_verified_operation_peers(context, receiver, [peer], digest)
        end

        verified

      _ ->
        record_result(context, receiver, actor, %{
          operation: nil,
          digest: digest,
          proof: nil,
          residual: :unknown,
          verified: false,
          terminal: "unaccepted_response",
          terminal_code: nil
        })

        false
    end
  end

  defp reconcile(context, receiver, actor, _name, digest, _beacon, {:error, error}) do
    Runner.record_detail(context, "daemon-probe-not-accepted/" <> receiver, %{
      "accepted" => false,
      "http_status" => error.http_status,
      "operation_id" => error.operation,
      "error_kind" => Atom.to_string(error.kind),
      "proof" => %{"actor" => actor, "receiver" => receiver, "nonce_sha256" => digest}
    })

    false
  end

  defp expected_failure?({:error, %Error{kind: :operation_failed}} = result),
    do: terminal_code(result) == 400

  defp expected_failure?(_), do: false

  defp retained_volume(context, actor, name) do
    case volume(context.sides[actor].client, context.config[actor]["pool"], name) do
      {:error, %Error{http_status: 404}} ->
        :absent

      {:ok, response} ->
        true = response.metadata.data["description"] == context.marker
        true = String.starts_with?(name, context.resource_prefix)
        :owned

      _ ->
        :unknown
    end
  end

  defp terminal_code({:error, %Error{response: %{metadata: metadata}}}) do
    case Model.encode(metadata) do
      data when is_map(data) -> data["status_code"]
      _ -> nil
    end
  end

  defp terminal_code({:ok, operation}), do: Operation.data(operation)["status_code"]
  defp terminal_code(_), do: nil

  defp terminal_status({:error, %Error{kind: kind}}), do: Atom.to_string(kind)
  defp terminal_status({:ok, _}), do: "unexpected_success"

  defp record_result(context, receiver, actor, result) do
    peer = if result.proof, do: result.proof.peer |> :inet.ntoa() |> to_string()

    Runner.record_detail(context, "daemon-probe-result/" <> receiver, %{
      "operation_id" => result.operation,
      "completed" => result.terminal in ["operation_failed", "unexpected_success"],
      "outcome" => if(result.verified, do: "verified", else: "unverified"),
      "native_status" => result.terminal,
      "proof" => %{
        "actor" => actor,
        "receiver" => receiver,
        "verified" => result.verified,
        "peer" => peer,
        "nonce_sha256" => result.digest,
        "retained_volume" => Atom.to_string(result.residual),
        "native_operation_status" => result.terminal_code
      }
    })
  end

  defp volume(client, pool, name),
    do:
      Incus.call(client, "GetStoragePoolVolume", %{
        "pool" => pool,
        "volType" => "custom",
        "name" => name
      })

  defp timeout(context) do
    case context.config["daemon_probe_timeout_ms"] do
      nil -> 35_000
      milliseconds when is_integer(milliseconds) and milliseconds in 100..45_000 -> milliseconds
      _ -> raise ArgumentError, "invalid bounded daemon probe timeout"
    end
  end

  defp escape(value), do: URI.encode(value, &URI.char_unreserved?/1)
end
