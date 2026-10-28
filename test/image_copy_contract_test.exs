defmodule Opsmaru.Incus.ImageCopyContractTest do
  @moduledoc "S05 image copy and its completion compared with the pinned CopyImage."
  use ExUnit.Case, async: false
  alias Opsmaru.Incus
  alias Opsmaru.Incus.{Connection, Context, Error, ImageCopy, Images, Operation, Server}
  alias Opsmaru.TestSupport.{HTTPFixture, TLSIdentity, WebSocketFixture}
  @driver Path.expand("../.integration/image-copy-driver", __DIR__)
  @extensions ~w(images_push_relay image_copy_profile)
  @metadata :binary.copy(<<0, 255, 128, 13, 10>>, 64)
  @rootfs :binary.copy(<<255, 0, 128, 1>>, 96)
  @guid "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

  setup_all do
    File.mkdir_p!(Path.dirname(@driver))

    {out, status} =
      System.cmd("mise", ["exec", "--", "go", "build", "-o", @driver, "./imagecopy"],
        cd: Path.expand("reference", __DIR__),
        env: [{"GOTOOLCHAIN", "local"}],
        stderr_to_stdout: true
      )

    assert status == 0, out
    :ok
  end

  setup do
    root = Path.join(System.tmp_dir!(), "op-s05-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  for transport <- [:unix, :https] do
    test "#{transport} S05 image copy and wait agree with the pinned CopyImage", %{root: root} do
      identity = identity(root, unquote(transport))
      modes = if unquote(transport) == :https, do: [:pull, :push, :relay], else: [:relay]

      for {mode, image, opts, extensions} <- cases(),
          mode in modes,
          outcome <- [:success, :failure, :cancel] do
        label = inspect({mode, opts, extensions, outcome})
        {source, target} = pair(root, identity, image, extensions, outcome)
        native = reference(root, identity, mode, image, opts, source, target, outcome)

        {source2, target2} = pair(root, identity, image, extensions, outcome)
        assert {:ok, %ImageCopy{} = copy} = copy(mode, image, opts, source2, target2), label
        driving = if mode == :push, do: copy.source, else: copy.target

        if outcome == :cancel do
          # A local deadline is not completion: no token is cancelled, no alias created.
          assert {:error, %Error{kind: :deadline, response: %{accepted: ^copy}}} =
                   Images.wait_copy(copy, timeout: 50)

          assert deletes(source2) == [] and deletes(target2) == []
          assert count(source2, target2, :alias) == 0
          assert native["canceled"], label
          assert {:ok, _} = Operation.cancel(driving)
        end

        waited = Images.wait_copy(copy, timeout: 3_000)

        case outcome do
          :success ->
            assert native["completed"], label <> inspect(native)
            assert {:ok, %ImageCopy{} = done} = waited, label
            assert Operation.successful?(if mode == :push, do: done.source, else: done.target)

          _ when mode == :relay ->
            # Recorded difference: the pinned relay builds its failure with
            # remoteOperationError(msg, nil), which is nil, so a failed or cancelled
            # upload reports success (and still creates no alias). This reports it.
            assert native["completed"], label <> inspect(native)

            assert {:error, %Error{kind: :operation_failed, response: %{accepted: kept}}} =
                     waited

            assert kept.target

          _ ->
            assert native["error"], label
            assert {:error, %Error{kind: :operation_failed, response: %{accepted: kept}}} = waited
            assert kept.target && (mode != :push or kept.source)
        end

        # The same mutations, bodies and headers reached each side in the same order.
        assert mutations(source2) == mutations(source), label
        assert mutations(target2) == mutations(target), label

        # Only the driving operation is waited on; a push also reads its token to cancel it.
        driving_id = if mode == :push, do: "export", else: "copy"
        read = operation_reads(source2) ++ operation_reads(target2)
        assert driving_id in read, label
        assert Enum.uniq(read) -- [driving_id, "token"] == [], label
        if mode != :push, do: refute("token" in read)
      end
    end

    test "#{transport} S05 lost or malformed copy replies are uncertain and never replayed", %{
      root: root
    } do
      identity = identity(root, unquote(transport))
      modes = if unquote(transport) == :https, do: [:pull, :push, :relay], else: [:relay]
      image = image(:unified)
      opts = [aliases: [%{"name" => "one"}, %{"name" => "two"}]]

      for mode <- modes, reply <- [:lost, :malformed] do
        # Each mutation of the copy in order, with the handles accepted before it.
        steps =
          case mode do
            :pull -> [{:secret, []}, {:create, [source: "secret"]}]
            :push -> [{:token, []}, {:export, [target: "token"]}]
            :relay -> [{:upload, []}]
          end

        for {kind, kept} <- steps do
          {source, target} = pair(root, identity, image, @extensions, :success, %{kind => reply})

          assert {:error, %Error{kind: :uncertain, response: %{accepted: accepted}}} =
                   copy(mode, image, opts, source, target),
                 inspect({mode, kind, reply})

          for side <- [:source, :target] do
            case kept[side] do
              nil -> assert is_nil(Map.fetch!(accepted, side))
              id -> assert Map.fetch!(accepted, side).url == "/1.0/operations/" <> id
            end
          end

          # The lost request was sent once, nothing after it was sent, nothing cancelled.
          assert count(source, target, kind) == 1
          assert Enum.all?(later(mode, kind), &(count(source, target, &1) == 0))
          assert deletes(source) == [] and deletes(target) == []
        end

        # A lost alias creation stops the cleanup: the copy stays, nothing is resent.
        if mode != :push do
          {source, target} = pair(root, identity, image, @extensions, :success, %{alias: reply})
          assert {:ok, copy} = copy(mode, image, opts, source, target)

          assert {:error, %Error{kind: :uncertain, response: %{accepted: kept}}} =
                   Images.wait_copy(copy, timeout: 3_000)

          assert Operation.successful?(kept.target)
          assert count(source, target, :alias) == 1
          assert deletes(source) == [] and deletes(target) == []
        end
      end
    end
  end

  test "https S05 copy guards agree with the pinned CopyImage before any mutation", %{
    root: root
  } do
    identity = identity(root, :https)
    image = image(:unified)

    for mode <- [:pull, :push, :relay] do
      # A profile override needs image_copy_profile on the target, before any request.
      {source, target} = pair(root, identity, image, ~w(images_push_relay), :success)
      native = reference(root, identity, mode, image, [profiles: ["p"]], source, target, :wait)
      assert native["error"] =~ "image_copy_profile"

      {source2, target2} = pair(root, identity, image, ~w(images_push_relay), :success)

      assert {:error, %Error{kind: :unsupported_extension, extension: "image_copy_profile"}} =
               copy(mode, image, [profiles: ["p"]], source2, target2)

      assert mutations(source) == [] and mutations(target) == []
      assert mutations(source2) == [] and mutations(target2) == []
    end

    # Recorded difference: the pinned push asks the target for a token, fails the
    # source's images_push_relay guard in ExportImage and cancels the token. This
    # client refuses before the token request, so nothing is created or cancelled.
    {source, target} = pair(root, identity, image, ~w(image_copy_profile), :success)
    native = reference(root, identity, :push, image, [], source, target, :wait)
    assert native["error"] =~ "images_push_relay"

    assert [{"POST", "/1.0/images" <> _, _}, {"DELETE", "/1.0/operations/token" <> _, _}] =
             mutations(target)

    {source, target} = pair(root, identity, image, ~w(image_copy_profile), :success)

    assert {:error, %Error{kind: :unsupported_extension, extension: "images_push_relay"}} =
             copy(:push, image, [], source, target)

    assert mutations(source) == [] and mutations(target) == []

    # Pull and push connect the other side to the approved origin only.
    {source, target} = pair(root, identity, image, @extensions, :success)

    for {mode, origin} <- [pull: target.origin, push: source.origin, pull: nil, push: nil] do
      opts = [mode: Atom.to_string(mode)] ++ if(origin, do: [approved_origin: origin], else: [])

      assert {:error, %Error{kind: :unapproved_copy_origin}} =
               Images.copy(target.client, source.client, image, opts)
    end

    assert {:error, %Error{kind: :same_backend}} =
             Images.copy(source.client, source.client, image, mode: "relay")

    assert {:error, %Error{kind: :invalid_copy_options}} =
             Images.copy(target.client, source.client, image, retries: 1)

    assert mutations(source) == [] and mutations(target) == []
  end

  test "unix S05 pull and push need an approved HTTPS origin before any request", %{root: root} do
    image = image(:unified)
    {source, target} = pair(root, nil, image, @extensions, :success)

    for mode <- [:pull, :push] do
      assert {:error, %Error{kind: :unapproved_copy_origin}} =
               copy(mode, image, [], source, target)
    end

    assert HTTPFixture.requests(source.fixture) == []
    assert HTTPFixture.requests(target.fixture) == []
  end

  # {mode, image, copy options, extensions on both sides}. Pull against a server
  # without image_create_aliases creates the aliases after the copy, as natively.
  defp cases do
    aliases = [%{"name" => "one", "description" => "first"}, %{"name" => "two"}]
    newer = @extensions ++ ~w(image_create_aliases)

    [
      {:pull, image(:unified),
       [aliases: aliases, copy_aliases: true, auto_update: true, public: true, type: "container"],
       @extensions},
      {:pull, image(:unified), [aliases: aliases, profiles: ["p", "q"]], newer},
      {:pull, %{image(:unified) | "public" => true}, [], @extensions},
      {:push, image(:unified),
       [aliases: aliases, copy_aliases: true, auto_update: true, public: true], @extensions},
      {:push, image(:unified), [profiles: ["p"]], @extensions},
      {:relay, image(:unified), [aliases: aliases, public: true, auto_update: true], @extensions},
      {:relay, image(:split), [copy_aliases: true, profiles: ["p"]], @extensions}
    ]
  end

  defp image(kind) do
    {type, bytes} =
      if kind == :split,
        do: {"virtual-machine", @metadata <> @rootfs},
        else: {"container", @metadata}

    %{
      "fingerprint" => fingerprint(bytes),
      "public" => false,
      "type" => type,
      "filename" => "native.tar.xz",
      "aliases" => [%{"name" => "base", "description" => "native"}],
      "properties" => %{"os" => "fixture", "release" => "1"},
      "profiles" => ["source-only"],
      "expires_at" => "2030-01-01T00:00:00Z"
    }
  end

  defp copy(mode, image, opts, source, target) do
    origin =
      case mode do
        :pull -> source.origin
        :push -> target.origin
        :relay -> nil
      end

    opts = [mode: Atom.to_string(mode)] ++ opts
    opts = if origin, do: Keyword.put(opts, :approved_origin, origin), else: opts

    opts =
      if mode == :relay,
        do: Keyword.put(opts, :relay, stage(image["type"] == "virtual-machine")),
        else: opts

    Images.copy(target.client, source.client, image, opts)
  end

  # Host staging: an agent per part, replayed as the upload source.
  defp stage(split) do
    {:ok, agent} = Agent.start_link(fn -> %{metadata: [], rootfs: []} end)

    sink = fn kind ->
      fn bytes -> Agent.update(agent, &Map.update!(&1, kind, fn c -> [bytes | c] end)) end
    end

    replay = fn kind -> fn -> Agent.get(agent, &Enum.reverse(Map.fetch!(&1, kind))) end end
    adapter = %{metadata_sink: sink.(:metadata), metadata_source: replay.(:metadata)}

    if split,
      do: Map.merge(adapter, %{rootfs_sink: sink.(:rootfs), rootfs_source: replay.(:rootfs)}),
      else: adapter
  end

  defp reference(root, identity, mode, image, opts, source, target, outcome) do
    args = %{
      Mode: Atom.to_string(mode),
      Aliases: opts[:aliases],
      CopyAliases: opts[:copy_aliases] == true,
      AutoUpdate: opts[:auto_update] == true,
      Public: opts[:public] == true,
      Type: opts[:type] || "",
      Profiles: opts[:profiles]
    }

    input = %{
      after: if(outcome == :cancel, do: "cancel", else: "wait"),
      source: native(source, identity),
      target: native(target, identity),
      image: image,
      args: args,
      temp: root
    }

    file = Path.join(root, "copy-#{System.unique_integer([:positive])}.json")
    File.write!(file, Jason.encode!(input))
    File.chmod!(file, 0o600)
    {out, status} = System.cmd(@driver, [file], stderr_to_stdout: true)
    assert status == 0, out
    Jason.decode!(out)
  end

  defp native(side, nil), do: %{socket: side.endpoint.socket, project: "fixture"}

  defp native(side, identity),
    do: %{
      url: side.endpoint.url,
      server_cert: File.read!(identity.certfile),
      client_cert: File.read!(identity.certfile),
      client_key: File.read!(identity.keyfile),
      project: "fixture"
    }

  # Every POST and DELETE a side received, in order: JSON bodies compared as the Go
  # DTO decodes them (zero values dropped), uploads by their headers and parts.
  defp mutations(side) do
    for request <- HTTPFixture.requests(side.fixture), request.method in ["POST", "DELETE"] do
      {request.method, request.target, body(request)}
    end
  end

  defp body(%{body: ""}), do: nil

  defp body(request) do
    case request.headers["content-type"] do
      "application/json" <> _ ->
        zero(Jason.decode!(request.body))

      "multipart/form-data" <> _ ->
        {headers(request), parts(request)}

      type ->
        {type, headers(request), request.body}
    end
  end

  defp headers(request),
    do: Enum.sort(for {"x-incus-" <> _ = key, value} <- request.headers, do: {key, value})

  defp zero(map) when is_map(map) do
    map
    |> Enum.map(fn {key, value} -> {key, zero(value)} end)
    |> Enum.reject(fn {_, value} -> value in [nil, "", false, 0, [], %{}] end)
    |> Map.new()
  end

  defp zero(list) when is_list(list), do: Enum.map(list, &zero/1)
  # The other side's origin differs between fixture pairs; Go's zero time is a zero value.
  defp zero("https://localhost:" <> _), do: "origin"
  defp zero("0001-01-01T00:00:00Z"), do: nil
  defp zero(value), do: value

  # Every multipart part as {form name, filename, bytes}.
  defp parts(request) do
    {_, _, params} = :cow_http_hd.parse_content_type(request.headers["content-type"])
    {_, boundary} = List.keyfind(params, "boundary", 0)
    parts(request.body, boundary, [])
  end

  defp parts(body, boundary, acc) do
    case :cow_multipart.parse_headers(body, boundary) do
      {:ok, headers, rest} ->
        {_, disposition} = List.keyfind(headers, "content-disposition", 0)
        {"form-data", params} = :cow_multipart.parse_content_disposition(disposition)
        {:done, bytes, rest} = :cow_multipart.parse_body(rest, boundary)
        name = elem(List.keyfind(params, "name", 0), 1)
        filename = elem(List.keyfind(params, "filename", 0), 1)
        parts(rest, boundary, [{name, filename, bytes} | acc])

      {:done, _} ->
        Enum.reverse(acc)
    end
  end

  # The operation IDs a side's operation reads (waits and polls) named.
  defp operation_reads(side),
    do:
      for(
        request <- HTTPFixture.requests(side.fixture),
        request.method == "GET",
        "/1.0/operations/" <> rest <- [URI.parse(request.target).path],
        do: rest |> String.split("/") |> hd()
      )

  defp deletes(side), do: for({"DELETE", target, _} <- mutations(side), do: target)

  defp count(source, target, kind),
    do:
      Enum.count(
        HTTPFixture.requests(source.fixture) ++ HTTPFixture.requests(target.fixture),
        &(kind(&1) == kind)
      )

  defp later(:pull, :secret), do: [:create]
  defp later(:push, :token), do: [:export]
  defp later(_, _), do: [:alias]

  # The image copy request a fixture request is.
  defp kind(%{method: "POST"} = request) do
    case String.split(URI.parse(request.target).path, "/", trim: true) do
      ["1.0", "images", "aliases"] -> :alias
      ["1.0", "images", _, "secret"] -> :secret
      ["1.0", "images", _, "export"] -> :export
      ["1.0", "images"] -> image_post(request)
      _ -> :other
    end
  end

  defp kind(_request), do: :read

  defp image_post(request) do
    case request.headers["content-type"] do
      "application/json" <> _ ->
        if get_in(Jason.decode!(request.body), ["source", "mode"]) == "push",
          do: :token,
          else: :create

      _ ->
        :upload
    end
  end

  # Source and target backends serving one image, whose copy operation ends with
  # `outcome` and whose mutation replies of the given kinds are lost or malformed.
  defp pair(root, identity, image, extensions, outcome, replies \\ %{}) do
    sides =
      for name <- ["source", "target"],
          do: backend(root, identity, name, image, extensions, outcome, replies)

    List.to_tuple(sides)
  end

  defp backend(root, identity, name, image, extensions, outcome, replies) do
    state = start_supervised!({Agent, fn -> MapSet.new() end}, id: make_ref())
    certificate = if identity, do: File.read!(identity.certfile), else: ""

    side = %{
      name: name,
      image: image,
      extensions: extensions,
      certificate: certificate,
      outcome: outcome,
      replies: replies,
      state: state
    }

    options =
      if identity,
        do: [
          transport: :ssl,
          certfile: identity.certfile,
          keyfile: identity.keyfile,
          peer_options: [
            cacertfile: identity.cafile,
            verify: :verify_peer,
            fail_if_no_peer_cert: true
          ]
        ],
        else: [
          transport: :gen_tcp,
          path: Path.join(root, "#{name}-#{System.unique_integer([:positive])}")
        ]

    handler = &respond(side, &1)
    fixture = start_supervised!({HTTPFixture, options ++ [handler: handler]}, id: make_ref())
    endpoint = HTTPFixture.endpoint(fixture)
    connection_opts = [owner: :fixture, project: "fixture", timeout: 5_000]

    connection =
      if identity,
        do:
          Connection.https!(
            endpoint.url,
            connection_opts ++
              [
                tls: [
                  cacertfile: identity.cafile,
                  certfile: identity.certfile,
                  keyfile: identity.keyfile
                ]
              ]
          ),
        else: Connection.unix!(endpoint.socket, connection_opts)

    client = %Incus{
      connection: connection,
      context: Context.new!(owner: :fixture, identity: :verified, ready?: fn -> true end),
      server: %Server{
        api_extensions: extensions,
        environment: %{"server_name" => name, "certificate" => certificate}
      }
    }

    %{name: name, fixture: fixture, endpoint: endpoint, client: client, origin: endpoint[:url]}
  end

  defp respond(side, request) do
    path = URI.parse(request.target).path

    case {request.method, String.split(path, "/", trim: true)} do
      {"GET", ["1.0"]} ->
        discovery(side)

      {"POST", _} ->
        case side.replies[kind(request)] do
          :lost -> %{raw: ""}
          :malformed -> %{status: 200, body: "malformed"}
          nil -> mutation(kind(request))
        end

      # The pinned upload's operation waits on the event stream rather than /wait.
      {"GET", ["1.0", "events"]} ->
        %{upgrade: &events(side, request, &1, &2)}

      {"GET", ["1.0", "images", _, "export"]} ->
        export(side.image)

      {"GET", ["1.0", "operations", id | wait]} ->
        # The pinned wait blocks on /wait until the operation is final; polls answer now.
        if wait != [], do: settle(side, id, System.monotonic_time(:millisecond) + 3_000)
        %{status: 200, body: %{type: "sync", metadata: operation(side, id)}}

      {"DELETE", ["1.0", "operations", id]} ->
        Agent.update(side.state, &MapSet.put(&1, id))
        %{status: 200, body: %{type: "sync", status_code: 200, metadata: %{}}}
    end
  end

  defp discovery(side),
    do: %{
      status: 200,
      body: %{
        type: "sync",
        metadata: %{
          api_version: "1.0",
          auth: "trusted",
          api_extensions: side.extensions,
          environment: %{server_name: side.name, certificate: side.certificate}
        }
      }
    }

  defp mutation(:alias),
    do: %{status: 200, body: %{type: "sync", status_code: 200, metadata: %{}}}

  defp mutation(:secret), do: accepted("secret", %{secret: "pull-secret"})
  defp mutation(:token), do: accepted("token", %{secret: "push-secret"})
  defp mutation(:export), do: accepted("export", %{})
  defp mutation(_create_or_upload), do: accepted("copy", %{})

  defp accepted(id, metadata),
    do: %{
      status: 202,
      body: %{
        type: "async",
        status_code: 100,
        operation: "/1.0/operations/" <> id,
        metadata: running(id, metadata)
      }
    }

  defp running(id, metadata),
    do: %{
      id: id,
      class: if(id in ["copy", "export"], do: "task", else: "token"),
      status: "Running",
      status_code: 103,
      err: "",
      may_cancel: true,
      metadata: metadata
    }

  defp operation(side, id) do
    cond do
      MapSet.member?(Agent.get(side.state, & &1), id) ->
        %{id: id, status: "Cancelled", status_code: 401, err: "operation cancelled"}

      id not in ["copy", "export"] or side.outcome == :cancel ->
        running(id, if(id == "token", do: %{secret: "push-secret"}, else: %{}))

      side.outcome == :failure ->
        %{id: id, status: "Failure", status_code: 400, err: "boom", may_cancel: false}

      true ->
        %{
          id: id,
          status: "Success",
          status_code: 200,
          err: "",
          may_cancel: false,
          metadata: %{fingerprint: side.image["fingerprint"]}
        }
    end
  end

  defp settle(side, id, deadline) do
    if operation(side, id).status == "Running" and id in ["copy", "export"] and
         System.monotonic_time(:millisecond) < deadline do
      Process.sleep(10)
      settle(side, id, deadline)
    end
  end

  # Complete the upgrade, then send the copy operation's event once it is final.
  defp events(side, request, transport, socket) do
    accept = Base.encode64(:crypto.hash(:sha, request.headers["sec-websocket-key"] <> @guid))

    :ok =
      transport.send(socket, [
        "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Accept: ",
        accept,
        "\r\n\r\n"
      ])

    settle(side, "copy", System.monotonic_time(:millisecond) + 3_000)

    event = %{
      type: "operation",
      timestamp: "2026-10-28T00:00:00Z",
      metadata: operation(side, "copy")
    }

    transport.send(socket, WebSocketFixture.frame(1, Jason.encode!(event)))
    # Hold the stream until the client disconnects.
    transport.recv(socket, 0, 3_000)
  end

  defp export(%{"type" => "virtual-machine"}) do
    body =
      part("metadata", "meta.tar", @metadata) <>
        part("rootfs.img", "root.img", @rootfs) <> "--fixture-export--\r\n"

    raw(body, "multipart/form-data; boundary=fixture-export")
  end

  defp export(_image), do: raw(@metadata, "application/octet-stream")

  defp raw(body, type),
    do: %{
      raw:
        "HTTP/1.1 200 OK\r\nContent-Type: #{type}\r\nContent-Length: #{byte_size(body)}\r\nContent-Disposition: attachment; filename=\"meta.tar\"\r\n\r\n" <>
          body
    }

  defp part(name, filename, bytes),
    do:
      ~s(--fixture-export\r\nContent-Disposition: form-data; name="#{name}"; filename="#{filename}"\r\nContent-Type: application/octet-stream\r\n\r\n) <>
        bytes <> "\r\n"

  defp fingerprint(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  defp identity(_root, :unix), do: nil

  defp identity(root, :https),
    do: TLSIdentity.generate(root, "s05-#{System.unique_integer([:positive])}", "localhost")
end
