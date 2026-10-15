defmodule Opsmaru.Incus.OCITest do
  use ExUnit.Case, async: false
  alias Opsmaru.Incus.{Connection, Context, Error, Model, OCI, RequestContext}
  @driver Path.expand("../.integration/oci-driver", __DIR__)

  defmodule Adapter do
    @behaviour Opsmaru.Incus.OCI.Adapter
    def inspect_image(config, request) do
      send(config.owner, {:inspect, self(), request})
      config.inspect.(request)
    end

    def image_file(config, request, emit) do
      send(config.owner, {:export, self(), request})
      config.export.(request, emit)
    end

    def cleanup(config, id, outcome) do
      send(config.owner, {:cleanup, id, outcome})
      config.cleanup.(id, outcome)
    end
  end

  setup_all do
    File.mkdir_p!(Path.dirname(@driver))

    {out, status} =
      System.cmd("mise", ["exec", "--", "go", "build", "-o", @driver, "./oci"],
        cd: Path.expand("reference", __DIR__),
        env: [{"GOTOOLCHAIN", "local"}],
        stderr_to_stdout: true
      )

    assert status == 0, out
    :ok
  end

  test "construction remains passive; readiness and owner mismatch never invoke adapters" do
    client = client(ready: false)
    refute_receive {:inspect, _, _}
    assert {:error, %Error{kind: :host_not_ready}} = OCI.resolve(client, "alpine")
    assert {:error, %Error{kind: :host_not_ready}} = OCI.unsupported(client, "GetImages")
    mismatch = %{client | connection: %{client.connection | owner: :other}}
    assert {:error, %Error{kind: :owner_mismatch}} = OCI.resolve(mismatch, "alpine")
    refute_receive {:cleanup, _, _}
    refute inspect(client) =~ "private"
    assert_raise ArgumentError, fn -> OCI.new!(client.connection, client.context, String, nil) end
  end

  test "native aliases, layered fingerprints, architectures and complete image JSON match pinned OCI" do
    for arch <-
          ~w(i686 i386 i586 386 x86 generic_32 x86_64 amd64 generic_64 x86_64_v1 x86_64_v2 x86_64_v3 x86_64_v4 armv6l armel arm armv7l armhf armhfp armv7a_hardfp armv7 armv7a_vfpv3_hardfp armv8l aarch64 arm64 arm64_generic ppc powerpc ppc64 powerpc64 ppc64le ppc64el s390x mips mipsel mipsle mips64 mips64el mips64le riscv32 riscv64 loongarch64 loong64),
        name <- ["alpine:latest", "library/alpine:edge@sha256:pinned"] do
      data = info(arch)
      client = client(info: data)
      expected = oracle("resolve", name, "container", data)
      assert expected["ok"], inspect(expected)
      assert {:ok, models, next} = OCI.resolve(client, name, "container")
      assert Model.encode(models.alias) == expected["value"]["alias"]
      assert Model.encode(models.image) == expected["value"]["image"]
      fingerprint = models.alias.data["target"]
      assert {:ok, %{metadata: image}} = OCI.image(next, fingerprint)
      assert image == models.image
      assert {:error, %Error{message: "Image not found"}} = OCI.image(client, fingerprint)
      assert_receive {:inspect, _, request}
      assert_receive {:cleanup, id, :completed}
      assert id == request.call_id
      assert request.alias == expected["value"]["alias"]["name"]
    end
  end

  test "native zero values, null layers, nanoseconds and signed int64 size overflow match" do
    for data <- [
          %{"Architecture" => "x86_64"},
          Map.merge(info(), %{"Layers" => nil, "LayersData" => [nil, %{}]}),
          Map.put(info(), "LayersData", [%{"Size" => 9_223_372_036_854_775_807}, %{"Size" => 1}]),
          Map.put(info(), "Created", "2026-10-11T01:00:00.123456789+01:00")
        ] do
      expected = oracle("resolve", "alpine", "", data)
      assert expected["ok"], inspect(expected)
      assert {:ok, models, _} = OCI.resolve(client(info: data), "alpine")
      assert Model.encode(models.image) == expected["value"]["image"]
    end
  end

  test "native alias architecture keys use the explicit local architecture, not image architecture" do
    for image_arch <- ["amd64", "arm64"], type <- ["", "container", "other"] do
      data = info(image_arch)
      expected = oracle("GetImageAliasArchitectures", "alpine", type, data)
      assert expected["ok"]

      assert {:ok, aliases, next} =
               OCI.alias_architectures(
                 client(info: data),
                 "alpine",
                 expected["local_architecture"],
                 type
               )

      assert Map.new(aliases, fn {arch, model} -> {arch, Model.encode(model)} end) ==
               expected["value"]

      [alias_model] = Map.values(aliases)
      assert {:ok, %{metadata: image}} = OCI.image(next, alias_model.data["target"])
      assert image.data["architecture"] in ["x86_64", "aarch64"]
      assert_receive {:inspect, _, _}
      assert_receive {:cleanup, _, :completed}
    end
  end

  test "architecture helper rejects local configuration and native VM type before adapter work" do
    for architecture <- [nil, 42, "not-an-architecture"] do
      assert {:error, %Error{kind: :invalid_architecture}} =
               OCI.alias_architectures(client(), "alpine", architecture)
    end

    expected = oracle("GetImageAliasArchitectures", "alpine", "virtual-machine", info())

    assert {:error, %Error{kind: :native, message: message}} =
             OCI.alias_architectures(client(), "alpine", "aarch64", "virtual-machine")

    assert message == expected["error"]
    refute_receive {:inspect, _, _}
    refute_receive {:cleanup, _, _}
  end

  test "OCI disconnect matches native no-op and never activates an adapter" do
    assert oracle("Disconnect", "", "", %{})["value"] == "ok"
    client = client(ready: false)
    assert :ok = OCI.disconnect(client)
    assert client.cache == %{}
    refute_receive {:inspect, _, _}
    refute_receive {:cleanup, _, _}
  end

  test "all native unsupported methods preserve errors without registry/tool calls" do
    client = client()

    for method <-
          ~w(GetImages GetImagesAllProjects GetImagesAllProjectsWithFilter GetImagesWithFilter GetImageFingerprints GetImageAliases GetImageAliasNames GetImageSecret GetPrivateImage GetPrivateImageFile ExportImage) do
      expected = oracle(method, "missing", "", %{})
      assert {:error, %Error{kind: :native, message: message}} = OCI.unsupported(client, method)
      assert message == expected["error"]
    end

    refute_receive {:inspect, _, _}
    refute_receive {:cleanup, _, _}
    expected = oracle("resolve", "alpine", "virtual-machine", info())
    assert {:error, %Error{message: message}} = OCI.resolve(client, "alpine", "virtual-machine")
    assert message == expected["error"]
  end

  test "malformed, oversized inspection and unsupported architecture fail with cleanup and no secret output" do
    for data <- [
          "private invalid JSON",
          String.duplicate("x", 1_048_577),
          Jason.encode!(info("unknown")),
          Jason.encode!(%{"Architecture" => "x86_64", "Layers" => [7]}),
          Jason.encode!(%{"Architecture" => "x86_64", "LayersData" => [%{"Size" => "bad"}]})
        ] do
      client = client(inspect: fn _ -> {:ok, data} end)

      assert {:error, %Error{kind: :invalid_oci_inspection} = error} =
               OCI.resolve(client, "alpine")

      refute inspect(error) =~ "private"
      assert_receive {:cleanup, _, :failed}
    end
  end

  test "bounded immutable cache and per-connection credential/config isolation" do
    first = client(queue_limit: 1)
    assert {:ok, _, next} = OCI.resolve(first, "one")
    assert {:error, %Error{kind: :oci_cache_limit}} = OCI.resolve(next, "two")
    second = client(info: %{info() | "Layers" => ["other"]})
    assert {:ok, models, _} = OCI.resolve(second, "two")

    assert {:error, %Error{message: "Image not found"}} =
             OCI.image(next, models.image.data["fingerprint"])

    assert next.connection == first.connection
    assert first.cache == %{}
  end

  test "structured host failures survive cleanup and remain redacted" do
    failure = %Error{
      kind: :native,
      error_code: 403,
      message: "private auth error",
      operation: "native-id"
    }

    assert {:error, ^failure} =
             OCI.resolve(client(inspect: fn _ -> {:error, failure} end), "alpine")

    assert_receive {:cleanup, _, :failed}

    assert {:error, %Error{kind: :adapter_cleanup, response: {:error, ^failure}} = error} =
             OCI.resolve(
               client(inspect: fn _ -> {:error, failure} end, cleanup: fn _, _ -> :error end),
               "alpine"
             )

    refute inspect(error) =~ "private"

    export_client = resolved(client(export: fn _, _ -> {:error, failure} end))

    assert {:error, ^failure} =
             OCI.image_file(export_client, fingerprint(export_client), %{
               metadata: fn _ -> :ok end,
               rootfs: fn _ -> :ok end
             })
  end

  test "foreign emitters cannot deliver bytes or conceal a rejection" do
    owner = self()

    client =
      resolved(
        client(
          export: fn _, emit ->
            task = Task.async(fn -> emit.(:metadata, <<1>>) end)
            assert {:error, :foreign_emitter} = Task.await(task)
            emit.(:metadata, <<2>>)
            :ok
          end
        )
      )

    assert {:error, %Error{kind: :adapter_stream}} =
             OCI.image_file(client, fingerprint(client), %{
               metadata: fn _ ->
                 send(owner, :rejected_output)
                 :ok
               end,
               rootfs: fn _ -> :ok end
             })

    assert_receive {:cleanup, _, :failed}
    refute_receive :rejected_output
  end

  test "cleanup has an independent bounded deadline and kills trapping cleanup workers" do
    owner = self()

    client =
      client(
        timeout: 60,
        cleanup: fn _, _ ->
          send(owner, {:cleaner, self()})
          Process.flag(:trap_exit, true)

          receive do
            :never -> :ok
          end
        end
      )

    started = System.monotonic_time(:millisecond)
    assert {:error, %Error{kind: :adapter_cleanup}} = OCI.resolve(client, "alpine")
    assert System.monotonic_time(:millisecond) - started < 500
    assert_receive {:cleaner, worker}
    monitor = Process.monitor(worker)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}
  end

  test "binary metadata/rootfs are acknowledged, counted and never encoded or replayed" do
    owner = self()

    client =
      resolved(
        client(
          export: fn _, emit ->
            assert :ok = emit.(:metadata, <<0, 255, 1>>)
            assert :ok = emit.(:rootfs, <<2, 0, 254>>)
            :ok
          end
        )
      )

    sinks = %{
      metadata: fn bytes ->
        send(owner, {:meta, bytes})
        :ok
      end,
      rootfs: fn bytes ->
        send(owner, {:rootfs, bytes})
        :ok
      end
    }

    assert {:ok,
            %{
              meta_size: 3,
              rootfs_size: 3,
              meta_name: "metadata.tar.gz",
              rootfs_name: "rootfs.tar.gz"
            }} = OCI.image_file(client, fingerprint(client), sinks)

    assert_receive {:meta, <<0, 255, 1>>}
    assert_receive {:rootfs, <<2, 0, 254>>}
    assert_receive {:export, _, request}
    assert_receive {:cleanup, id, :completed}
    assert id == request.call_id
    refute_receive {:export, _, _}
  end

  test "chunk, total byte, invalid channel and sink failures remain sticky even if adapter ignores rejection" do
    for {connection, chunks, sink} <- [
          {[max_chunk_bytes: 2], [{:metadata, <<1, 2, 3>>}], fn _ -> :ok end},
          {[max_stream_bytes: 3], [{:metadata, <<1, 2>>}, {:rootfs, <<3, 4>>}], fn _ -> :ok end},
          {[], [{:unknown, <<1>>}], fn _ -> :ok end},
          {[], [{:metadata, <<1>>}], fn _ -> :error end}
        ] do
      client =
        client(
          connection ++
            [
              export: fn _, emit ->
                Enum.each(chunks, fn {part, bytes} -> emit.(part, bytes) end)
                :ok
              end
            ]
        )
        |> resolved()

      sinks = %{metadata: sink, rootfs: sink}

      assert {:error, %Error{kind: :adapter_stream}} =
               OCI.image_file(client, fingerprint(client), sinks)

      assert_receive {:export, _, _}
      assert_receive {:cleanup, _, :failed}
      refute_receive {:export, _, _}
    end
  end

  test "inspection deadline kills trapping worker and performs bounded per-call cleanup once" do
    client =
      client(
        timeout: 60,
        inspect: fn _ ->
          Process.flag(:trap_exit, true)

          receive do
            :never -> {:ok, "{}"}
          end
        end
      )

    result = OCI.resolve(client, "alpine")

    pending =
      case result do
        {:error, %Error{kind: :adapter_deadline}} ->
          nil

        {:error, %Error{kind: :adapter_cleanup, response: %{cleanup_pending: true} = pending}} ->
          # On a slow scheduler the caller stops waiting before the controller
          # reports; cleanup continues independently and stays visible.
          pending

        {:error, %Error{kind: :adapter_cleanup, response: primary}} ->
          # Cleanup has its own finite 60 ms budget. Missing it must stay visible,
          # while preserving the primary deadline; it is not successful cleanup.
          assert {:error, %Error{kind: :adapter_deadline}} = primary
          nil
      end

    assert_receive {:inspect, worker, request}
    if pending, do: assert(pending.call_id == request.call_id)
    monitor = Process.monitor(worker)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}
    assert_receive {:cleanup, id, :deadline}
    assert id == request.call_id
    refute_receive {:cleanup, _, _}
  end

  test "sink exceptions caught by the adapter stay sticky and prevent later output" do
    owner = self()

    for failure <- [
          fn -> raise "private sink" end,
          fn -> throw(:private_sink) end,
          fn -> exit(:private_sink) end
        ] do
      client =
        resolved(
          client(
            export: fn _, emit ->
              try do
                emit.(:metadata, <<1>>)
              rescue
                _ -> :ignored
              catch
                _, _ -> :ignored
              end

              emit.(:rootfs, <<2>>)
              :ok
            end
          )
        )

      sinks = %{
        metadata: fn _ ->
          send(owner, :sink_attempt)
          failure.()
        end,
        rootfs: fn _ ->
          send(owner, :later_output)
          :ok
        end
      }

      assert {:error, %Error{kind: :adapter_stream}} =
               OCI.image_file(client, fingerprint(client), sinks)

      assert_receive :sink_attempt
      refute_receive :later_output
      assert_receive {:cleanup, _, :failed}
    end
  end

  test "caller loss kills export callback and runs cleanup without stopping other host work" do
    owner = self()

    client =
      resolved(
        client(
          export: fn _, _ ->
            Process.flag(:trap_exit, true)

            receive do
              :never -> :ok
            end
          end
        )
      )

    caller =
      spawn(fn ->
        OCI.image_file(client, fingerprint(client), %{
          metadata: fn _ -> :ok end,
          rootfs: fn _ -> :ok end
        })
      end)

    assert_receive {:export, worker, request}
    monitor = Process.monitor(worker)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}
    assert_receive {:cleanup, id, :owner_lost}
    assert id == request.call_id
    assert Process.alive?(owner)
    assert {:ok, _} = OCI.image(client, fingerprint(client))
  end

  test "sink deadline, callback exceptions and cleanup failures do not leak or retry" do
    for opts <- [
          [stream_timeout: 40, export: fn _, emit -> emit.(:metadata, <<1>>) end],
          [export: fn _, _ -> raise "private credential" end],
          [cleanup: fn _, _ -> raise "private cleanup" end]
        ] do
      # Resolve with normal cleanup, then install the failure for export only.
      base = resolved(client())
      failing = client(opts)
      client = %{base | config: failing.config, connection: failing.connection}

      result =
        OCI.image_file(client, fingerprint(client), %{
          metadata: fn _ ->
            Process.sleep(200)
            :ok
          end,
          rootfs: fn _ -> :ok end
        })

      assert {:error, %Error{} = error} = result
      refute inspect(error) =~ "private"
      assert_receive {:export, _, _}
      assert_receive {:cleanup, _, _}
      refute_receive {:export, _, _}
    end
  end

  test "request context cancellation stops adapter work before per-call cleanup" do
    scope = RequestContext.new!(timeout: 3_000)
    parent = self()

    original =
      client(
        inspect: fn _ ->
          Process.flag(:trap_exit, true)
          send(parent, {:blocked_adapter, self()})

          receive do
            :never -> :ok
          end
        end
      )

    scoped = %{original | connection: Connection.with_context(original.connection, scope)}
    task = Task.async(fn -> OCI.resolve(scoped, "alpine") end)
    assert_receive {:blocked_adapter, pid}, 500
    monitor = Process.monitor(pid)
    RequestContext.cancel(scope)
    assert {:error, %Error{kind: :adapter_canceled}} = Task.await(task, 500)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 500
    assert_receive {:cleanup, _, :canceled}, 500
    assert original.connection.request_context == nil
  end

  defp client(opts \\ []) do
    data = opts[:info] || info()

    connection =
      Connection.unix!(
        "/private/oci-fixture-not-opened.sock",
        [owner: :fixture] ++
          Keyword.take(opts, [
            :timeout,
            :stream_timeout,
            :queue_limit,
            :max_chunk_bytes,
            :max_stream_bytes
          ])
      )

    context =
      Context.new!(
        owner: :fixture,
        identity: :verified,
        ready?: fn -> Keyword.get(opts, :ready, true) end
      )

    config = %{
      owner: self(),
      inspect: opts[:inspect] || fn _ -> {:ok, Jason.encode!(data)} end,
      export: opts[:export] || fn _, _ -> :ok end,
      cleanup: opts[:cleanup] || fn _, _ -> :ok end
    }

    OCI.new!(connection, context, Adapter, config)
  end

  defp resolved(client) do
    assert {:ok, _, next} = OCI.resolve(client, "alpine")
    assert_receive {:inspect, _, _}
    assert_receive {:cleanup, _, :completed}
    next
  end

  defp fingerprint(client), do: client.cache |> Map.keys() |> hd()

  defp info(arch \\ "amd64"),
    do: %{
      "Name" => "registry/alpine",
      "Architecture" => arch,
      "Created" => "2026-10-11T00:00:00Z",
      "Layers" => ["sha256:one", "sha256:two"],
      "LayersData" => [%{"Size" => 2}, %{"Size" => 4}],
      "Digest" => "ignored",
      "future" => "ignored"
    }

  defp oracle(action, name, type, data) do
    # Temporary input is fixture JSON only; the native driver never uses a backend.
    path =
      Path.join(System.tmp_dir!(), "opsmaru-oci-input-#{System.unique_integer([:positive])}.json")

    File.write!(path, Jason.encode!(%{Action: action, Name: name, Type: type, Info: data}))

    try do
      {out, status} =
        System.cmd("sh", ["-c", "exec \"$1\" < \"$2\"", "oracle", @driver, path],
          stderr_to_stdout: true
        )

      assert status == 0, out
      Jason.decode!(out)
    after
      File.rm!(path)
    end
  end
end
