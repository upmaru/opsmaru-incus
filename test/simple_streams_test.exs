defmodule Opsmaru.Incus.SimpleStreamsTest do
  use ExUnit.Case, async: false
  alias Opsmaru.Incus.{Connection, Context, Error, HTTP, Model, SimpleStreams}
  alias Opsmaru.TestSupport.{HTTPFixture, TLSIdentity}
  @driver Path.expand("../.integration/simplestreams-driver", __DIR__)
  @http_driver Path.expand("../.integration/simplestreams-http-driver", __DIR__)
  @info_driver Path.expand("../.integration/origin-info-driver", __DIR__)

  defmodule DeltaAdapter do
    @behaviour Opsmaru.Incus.SimpleStreams.DeltaAdapter
    def convert(config, request, emit) do
      send(config.owner, {:delta_call, self(), request})
      config.convert.(request, emit)
    end

    def cleanup(config, id, outcome) do
      send(config.owner, {:delta_cleanup, id, outcome})
      config.cleanup.(id, outcome)
    end
  end

  setup_all do
    File.mkdir_p!(Path.dirname(@driver))

    {out, status} =
      System.cmd("mise", ["exec", "--", "go", "build", "-o", @driver, "./simplestreams"],
        cd: Path.expand("reference", __DIR__),
        env: [{"GOTOOLCHAIN", "local"}],
        stderr_to_stdout: true
      )

    assert status == 0, out

    {out, status} =
      System.cmd("mise", ["exec", "--", "go", "build", "-o", @http_driver, "./httpclient"],
        cd: Path.expand("reference", __DIR__),
        env: [{"GOTOOLCHAIN", "local"}],
        stderr_to_stdout: true
      )

    assert status == 0, out

    {out, status} =
      System.cmd("mise", ["exec", "--", "go", "build", "-o", @info_driver, "./origininfo"],
        cd: Path.expand("reference", __DIR__),
        env: [{"GOTOOLCHAIN", "local"}],
        stderr_to_stdout: true
      )

    assert status == 0, out
    :ok
  end

  test "SimpleStreams origin metadata matches native CA configuration without connecting or reading credentials",
       %{root: root, identity: identity} do
    fixture = http_fixture(identity, 200, "unused")
    endpoint = HTTPFixture.endpoint(fixture).url
    stream = client(endpoint, identity, "aarch64")
    path = Path.join(root, "origin-info.json")

    File.write!(
      path,
      Jason.encode!(%{URL: endpoint, CA: File.read!(identity.cafile), Protocol: "simplestreams"})
    )

    {out, status} =
      System.cmd("sh", ["-c", "exec \"$1\" < \"$2\"", "oracle", @info_driver, path],
        stderr_to_stdout: true
      )

    assert status == 0, out
    expected = Jason.decode!(out)
    # File references are irrelevant to this passive getter; no PEM is inferred
    # from CA roots or from a client certificate with another identity.
    for file <- [identity.cafile, identity.certfile, identity.keyfile], do: File.rm!(file)
    assert {:ok, info} = SimpleStreams.connection_info(stream)

    assert %{
             "Addresses" => info.addresses,
             "Certificate" => info.certificate,
             "Protocol" => info.protocol,
             "URL" => info.url,
             "SocketPath" => info.socket_path,
             "Project" => info.project,
             "Target" => info.target
           } == expected

    assert HTTPFixture.requests(fixture) == []
    refute inspect(info) =~ root
    unavailable = %{stream | context: %{stream.context | ready?: fn -> false end}}
    assert {:error, %Error{kind: :host_not_ready}} = SimpleStreams.connection_info(unavailable)
    mismatch = %{stream | connection: %{stream.connection | owner: :different}}
    assert {:error, %Error{kind: :owner_mismatch}} = SimpleStreams.connection_info(mismatch)
  end

  setup do
    root = Path.join(System.tmp_dir!(), "op-ss-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    identity = TLSIdentity.generate(root, "ss", "localhost")
    %{root: root, identity: identity}
  end

  for status <- [200, 305, 409] do
    test "SimpleStreams raw HTTP #{status} matches pinned native bytes and relative query", %{
      root: root,
      identity: identity
    } do
      status = unquote(status)
      bytes = <<0, 255, 128, 10, 13, 42>>
      fixture = http_fixture(identity, status, bytes)
      endpoint = HTTPFixture.endpoint(fixture).url
      stream = client(endpoint, identity, "aarch64")
      path = "/opaque%20path?selection=host+%2B&selection=second"

      expected =
        http_oracle(root, %{
          protocol: "simplestreams",
          url: endpoint,
          ca: File.read!(identity.cafile),
          cert: File.read!(identity.certfile),
          key: File.read!(identity.keyfile),
          server_cert: File.read!(identity.certfile),
          method: "POST",
          path: path,
          body: Base.encode64(bytes),
          headers: %{"if-match" => "native"}
        })

      [native] = HTTPFixture.requests(fixture)
      assert {:ok, handle} = SimpleStreams.http_client(stream)
      assert HTTPFixture.requests(fixture) == [native]

      assert {:ok, response} =
               HTTP.request(handle, "POST", path, body: bytes, headers: [{"if-match", "native"}])

      assert response.status == expected["status"]
      assert response.body == Base.decode64!(expected["body"])
      assert HTTP.Response.header(response, "etag") == expected["etag"]
      assert response.connection == stream.connection and response.identity == :verified
      [^native, actual] = HTTPFixture.requests(fixture)
      assert actual.target == native.target and actual.body == native.body
      assert actual.headers["if-match"] == native.headers["if-match"]
      refute Map.has_key?(actual.headers, "x-incus-authenticated")
      refute actual.target =~ "project="
      refute inspect(handle) =~ root
      refute inspect(response) =~ Base.encode64(bytes)
    end
  end

  test "origin HTTP rejects absolute URLs, traversal and malformed queries before I/O", %{
    identity: identity
  } do
    fixture = http_fixture(identity, 200, "ok")
    stream = client(HTTPFixture.endpoint(fixture).url, identity, "aarch64")

    for path <- [
          "https://other.invalid/file",
          "//other.invalid/file",
          "/../file",
          "/%2e%2e/file",
          "/file#fragment",
          "/file?x=%0d%0a",
          "/file?bad=%xx",
          "/file?x=" <> <<0>>,
          "relative",
          nil
        ] do
      assert {:error, %Error{kind: :invalid_path}} =
               SimpleStreams.http_request(stream, "GET", path)
    end

    assert HTTPFixture.requests(fixture) == []
  end

  test "origin HTTP preserves readiness and byte bounds and never follows redirects", %{
    identity: identity
  } do
    fixture = http_fixture(identity, 302, "redirect")
    stream = client(HTTPFixture.endpoint(fixture).url, identity, "aarch64")
    unavailable = %{stream | context: %{stream.context | ready?: fn -> false end}}

    assert {:error, %Error{kind: :host_not_ready}} =
             SimpleStreams.http_request(unavailable, "GET", "/file")

    bounded = %{stream | connection: %{stream.connection | max_request_bytes: 2}}

    assert {:error, %Error{kind: :invalid_http_request}} =
             SimpleStreams.http_request(bounded, "POST", "/file", body: "large")

    assert HTTPFixture.requests(fixture) == []
    assert {:ok, %{status: 302}} = SimpleStreams.http_request(stream, "GET", "/file")
    assert length(HTTPFixture.requests(fixture)) == 1
    bounded = %{stream | connection: %{stream.connection | max_response_bytes: 2}}

    assert {:error, %Error{kind: :response_limit}} =
             SimpleStreams.http_request(bounded, "GET", "/file")

    assert length(HTTPFixture.requests(fixture)) == 2
  end

  defp http_fixture(identity, status, bytes) do
    start_supervised!(
      {HTTPFixture,
       transport: :ssl,
       certfile: identity.certfile,
       keyfile: identity.keyfile,
       handler: fn _ ->
         %{
           raw:
             "HTTP/1.1 #{status} Fixture\r\nContent-Length: #{byte_size(bytes)}\r\nETag: native-origin\r\nLocation: https://other.invalid/file\r\nConnection: close\r\n\r\n" <>
               bytes
         }
       end},
      id: make_ref()
    )
  end

  defp http_oracle(root, input) do
    path = Path.join(root, "http-oracle.json")
    File.write!(path, Jason.encode!(input))

    {out, status} =
      System.cmd("sh", ["-c", "exec \"$1\" < \"$2\"", "oracle", @http_driver, path],
        stderr_to_stdout: true
      )

    assert status == 0, out
    Jason.decode!(out)
  end

  test "pinned catalog, newest preferred aliases, architectures and errors agree", %{
    root: root,
    identity: identity
  } do
    products = products()
    fixture = fixture(identity, products)
    endpoint = HTTPFixture.endpoint(fixture).url
    expected = oracle(root, endpoint, identity)
    client = client(endpoint, identity, expected["architecture"])
    assert expected["disconnect"] == "ok"
    assert :ok = SimpleStreams.disconnect(client)
    assert length(HTTPFixture.requests(fixture)) == 4
    assert {:error, %Error{kind: :catalog_not_loaded}} = SimpleStreams.images(client)
    refute inspect(client) =~ root
    assert {:ok, next} = SimpleStreams.refresh(client)
    assert client.catalog == nil
    assert_native_catalog(next, expected)
    before_disconnect = HTTPFixture.requests(fixture)
    assert :ok = SimpleStreams.disconnect(next)
    assert_native_catalog(next, expected)
    assert HTTPFixture.requests(fixture) == before_disconnect
    assert Enum.all?(HTTPFixture.requests(fixture), &(&1.method == "GET"))
    assert length(HTTPFixture.requests(fixture)) == 6
  end

  defp assert_native_catalog(next, expected) do
    assert {:ok, images} = SimpleStreams.images(next)
    assert Enum.map(images, &Model.encode/1) == expected["images"]
    assert expected["all"] == expected["images"]
    assert {:ok, expected["fingerprints"]} == SimpleStreams.fingerprints(next)
    assert {:ok, aliases} = SimpleStreams.aliases(next)
    actual = Enum.map(aliases, &Model.encode/1) |> Enum.sort_by(&(&1["name"] <> &1["type"]))
    assert actual == expected["aliases"]
    assert {:ok, names} = SimpleStreams.alias_names(next)
    assert Enum.sort(names) == expected["alias_names"]

    for {key, value} <- expected["selected"] do
      [name, type] = String.split(key, ":", parts: 2)
      assert_alias(SimpleStreams.alias(next, name, type), value)
      assert_architectures(SimpleStreams.alias_architectures(next, name, type), value)
    end

    for {fingerprint, value} <- expected["image_results"] do
      case SimpleStreams.image(next, fingerprint) do
        {:ok, image} ->
          assert Model.encode(image) == value["image"]

        {:error, %Error{message: message}} ->
          assert message == value["error"]
      end
    end

    for {method, message} <- expected["unsupported"] do
      assert {:error, %Error{kind: :native, message: ^message}} =
               SimpleStreams.unsupported(next, method)
    end

    for {fingerprint, expected_files} <- expected["files"] do
      assert {:ok, files} = SimpleStreams.files(next, fingerprint)

      actual =
        Map.new(files, fn {key, file} ->
          {key, %{"Path" => file.path, "Sha256" => file.sha256, "Size" => file.size}}
        end)

      assert actual == expected_files
    end
  end

  for type <- ~w(root.tar.xz squashfs disk-kvm.img disk1.img uefi1.img incus_combined.tar.gz) do
    test "pinned #{type} projections preserve optional fields, file manifests and aliases", %{
      root: root,
      identity: identity
    } do
      type = unquote(type)
      product = products()["amd64"]

      items = %{
        "meta" => %{
          "ftype" => "incus.tar.xz",
          "path" => "images/meta.tar.xz",
          "sha256" => "metadata-hash",
          "size" => 1,
          "combined_sha256" => "fallback",
          "combined_rootxz_sha256" => "rootxz",
          "combined_squashfs_sha256" => "squashfs",
          "combined_disk-kvm-img_sha256" => "kvm",
          "combined_disk1-img_sha256" => "disk",
          "combined_uefi1-img_sha256" => "uefi"
        },
        "root" => %{
          "ftype" => type,
          "path" => "images/root",
          "sha256" => "root-hash",
          "size" => 2
        }
      }

      items =
        if type == "incus_combined.tar.gz",
          do: %{"combined" => Map.put(items["root"], "combined_type", "virtual-machine")},
          else: items

      product = %{
        product
        | "versions" => %{
            "20261012extra" => %{"items" => items},
            "invalid" => %{"items" => items}
          },
          "support_eol" => "invalid"
      }

      product = Map.drop(product, ["version", "variant", "requirements"])

      fixture =
        fixture(identity, %{
          "fixture" => product,
          "unsupported" => Map.put(product, "arch", "unsupported")
        })

      expected = oracle(root, HTTPFixture.endpoint(fixture).url, identity)
      client = client(HTTPFixture.endpoint(fixture).url, identity, expected["architecture"])
      assert {:ok, next} = SimpleStreams.refresh(client)
      assert_native_catalog(next, expected)
    end
  end

  test "pinned delta manifest retains source fingerprint and byte/hash identity", %{
    root: root,
    identity: identity
  } do
    product = products()["amd64"]

    product =
      put_in(product, ["versions", "20261001", "items", "delta"], %{
        "ftype" => "squashfs.vcdiff",
        "path" => "images/delta.vcdiff",
        "sha256" => "delta-hash",
        "size" => 4,
        "delta_base" => "20260101"
      })

    fixture = fixture(identity, %{"fixture" => product})
    expected = oracle(root, HTTPFixture.endpoint(fixture).url, identity)
    client = client(HTTPFixture.endpoint(fixture).url, identity, expected["architecture"])
    assert {:ok, next} = SimpleStreams.refresh(client)
    assert_native_catalog(next, expected)
    assert {:ok, files} = SimpleStreams.files(next, "aabbamd64")

    assert files["root.delta-aaaaamd64"] == %{
             path: "images/delta.vcdiff",
             sha256: "delta-hash",
             size: 4
           }
  end

  test "redirect responses fail without forwarding credentials or retrying another origin", %{
    identity: identity
  } do
    fixture =
      start_supervised!(
        {HTTPFixture,
         transport: :ssl,
         certfile: identity.certfile,
         keyfile: identity.keyfile,
         handler: fn _ ->
           %{
             status: 302,
             headers: [{"location", "http://other.invalid/streams/v1/index.json"}],
             body: %{}
           }
         end}
      )

    client = client(HTTPFixture.endpoint(fixture).url, identity, "x86_64")
    assert {:error, %Error{kind: :simplestreams_response}} = SimpleStreams.refresh(client)
    assert [%{method: "GET", target: "/streams/v1/index.json"}] = HTTPFixture.requests(fixture)
  end

  test "binary parts preserve bytes, hashes, filenames and one HTTPS request per part", %{
    identity: identity
  } do
    metadata = <<0, 255, 13, 10, 5>>
    rootfs = :binary.copy(<<0, 255, 1>>, 10_000)
    {client, fixture} = download_client(identity, metadata, rootfs)
    owner = self()

    sinks = %{
      metadata: fn chunk ->
        send(owner, {:metadata, chunk})
        :ok
      end,
      rootfs: fn chunk ->
        send(owner, {:rootfs, chunk})
        :ok
      end
    }

    assert {:ok, result} = SimpleStreams.image_file(client, "image-fingerprint", sinks)

    assert result.metadata == %{
             name: "meta.tar.xz",
             size: byte_size(metadata),
             sha256: hash(metadata)
           }

    assert result.rootfs == %{
             name: "root.squashfs",
             size: byte_size(rootfs),
             sha256: hash(rootfs)
           }

    assert_received {:metadata, ^metadata}
    assert_received {:rootfs, ^rootfs}
    paths = Enum.map(HTTPFixture.requests(fixture), & &1.target)

    assert paths == [
             "/streams/v1/index.json",
             "/streams/v1/images.json",
             "/images/meta.tar.xz",
             "/images/root.squashfs"
           ]

    assert Enum.all?(HTTPFixture.requests(fixture), &(&1.method == "GET"))
  end

  test "checksum failure preserves image identity and never retries or starts the next part", %{
    identity: identity
  } do
    {client, fixture} = download_client(identity, "metadata", "rootfs", corrupt: true)
    sink = fn _ -> :ok end

    assert {:error, %Error{kind: :checksum, response: %{fingerprint: "image-fingerprint"}}} =
             SimpleStreams.image_file(client, "image-fingerprint", %{metadata: sink, rootfs: sink})

    assert Enum.map(HTTPFixture.requests(fixture), & &1.target) == [
             "/streams/v1/index.json",
             "/streams/v1/images.json",
             "/images/meta.tar.xz"
           ]
  end

  test "empty part, acknowledged sink failure and aggregate byte limits remain visible", %{
    identity: identity
  } do
    {client, fixture} = download_client(identity, "", "rootfs")

    assert {:ok, %{metadata: %{size: 0}}} =
             SimpleStreams.image_file(client, "image-fingerprint", %{
               metadata: fn _ -> flunk("empty body delivered a chunk") end
             })

    assert {:error, %Error{kind: :sink_failed}} =
             SimpleStreams.image_file(client, "image-fingerprint", %{
               rootfs: fn _ -> {:error, :host_rejection} end
             })

    limited = %{client | connection: %{client.connection | max_stream_bytes: 1}}
    before = length(HTTPFixture.requests(fixture))

    assert {:error, %Error{kind: :invalid_download_manifest}} =
             SimpleStreams.image_file(limited, "image-fingerprint", %{rootfs: fn _ -> :ok end})

    assert length(HTTPFixture.requests(fixture)) == before

    assert {:error, %Error{message: "No file requested"}} =
             SimpleStreams.image_file(client, "image-fingerprint", %{})
  end

  for cause <- [:deadline, :owner_loss] do
    test "#{cause} kills a stalled exit-trapping binary sink without replay", %{
      identity: identity
    } do
      {client, fixture} = download_client(identity, "metadata", "rootfs")
      # Owner loss gets a deadline it cannot reach, so only the owner's exit can
      # kill the sink; the deadline case leaves room to monitor the sink first.
      stream_timeout = if unquote(cause) == :deadline, do: 500, else: 30_000
      client = %{client | connection: %{client.connection | stream_timeout: stream_timeout}}
      parent = self()

      owner =
        spawn(fn ->
          result =
            SimpleStreams.image_file(client, "image-fingerprint", %{
              metadata: fn _ ->
                Process.flag(:trap_exit, true)
                send(parent, {:sink, self()})

                receive do
                  :never -> :ok
                end
              end
            })

          send(parent, {:download_result, result})
        end)

      on_exit(fn -> if Process.alive?(owner), do: Process.exit(owner, :kill) end)
      assert_receive {:sink, worker}, 1000
      monitor = Process.monitor(worker)
      if unquote(cause) == :owner_loss, do: Process.exit(owner, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 2_000

      if unquote(cause) == :deadline,
        do: assert_receive({:download_result, {:error, %Error{kind: :deadline}}}, 2_000)

      assert Enum.count(HTTPFixture.requests(fixture), &(&1.target == "/images/meta.tar.xz")) == 1
      refute Enum.any?(HTTPFixture.requests(fixture), &(&1.target == "/images/root.squashfs"))
    end
  end

  defp download_client(identity, metadata, rootfs, opts \\ []) do
    product = %{
      "arch" => "amd64",
      "aliases" => "download",
      "versions" => %{
        "20261001" => %{
          "items" => %{
            "meta" => %{
              "ftype" => "incus.tar.xz",
              "path" => "images/meta.tar.xz",
              "sha256" => hash(metadata),
              "size" => byte_size(metadata),
              "combined_squashfs_sha256" => "image-fingerprint"
            },
            "root" => %{
              "ftype" => "squashfs",
              "path" => "images/root.squashfs",
              "sha256" => hash(rootfs),
              "size" => byte_size(rootfs)
            }
          }
        }
      }
    }

    product = add_delta(product, opts[:delta])

    fixture =
      start_supervised!(
        {HTTPFixture,
         transport: :ssl,
         certfile: identity.certfile,
         keyfile: identity.keyfile,
         handler: fn request ->
           case request.target do
             "/streams/v1/index.json" ->
               %{
                 status: 200,
                 body: %{
                   "index" => %{
                     "images" => %{
                       "datatype" => "image-downloads",
                       "products" => ["fixture"],
                       "path" => "streams/v1/images.json"
                     }
                   }
                 }
               }

             "/streams/v1/images.json" ->
               %{status: 200, body: %{"products" => %{"fixture" => product}}}

             path ->
               bytes =
                 case path do
                   "/images/meta.tar.xz" -> metadata
                   "/images/delta.vcdiff" -> opts[:delta]
                   _ -> rootfs
                 end

               bytes = if opts[:corrupt], do: :binary.copy(<<7>>, byte_size(bytes)), else: bytes

               %{
                 raw:
                   "HTTP/1.1 200 OK\r\nContent-Length: #{byte_size(bytes)}\r\nConnection: close\r\n\r\n" <>
                     bytes
               }
           end
         end}
      )

    client = client(HTTPFixture.endpoint(fixture).url, identity, "x86_64")
    assert {:ok, next} = SimpleStreams.refresh(client)
    {next, fixture}
  end

  defp add_delta(product, nil), do: product

  defp add_delta(product, bytes) do
    current = product["versions"]["20261001"]
    base = put_in(current, ["items", "meta", "combined_squashfs_sha256"], "base-fingerprint")
    product = put_in(product, ["versions", "20260101"], base)

    put_in(product, ["versions", "20261001", "items", "delta"], %{
      "ftype" => "squashfs.vcdiff",
      "path" => "images/delta.vcdiff",
      "sha256" => hash(bytes),
      "size" => byte_size(bytes),
      "delta_base" => "20260101"
    })
  end

  defp hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  test "explicit delta adapter receives verified bytes/base and emits checksum-verified rootfs",
       %{identity: identity} do
    {client, fixture} =
      download_client(identity, "metadata", "converted-root", delta: "delta-bytes")

    parent = self()

    config =
      delta_config(fn request, emit ->
        assert request.base.source == :private_host_base
        assert request.connection == client.connection
        assert request.context == client.context

        assert {:ok, %{size: 11}} =
                 request.download_delta.(fn bytes ->
                   send(parent, {:delta_bytes, bytes})
                   :ok
                 end)

        :ok = emit.("converted-root")
        :ok
      end)

    client = with_delta(client, config)

    sink = fn bytes ->
      send(parent, {:root_bytes, bytes})
      :ok
    end

    assert {:ok, %{rootfs: %{size: 14}}} =
             SimpleStreams.image_file(client, "image-fingerprint", %{rootfs: sink},
               delta_base: %{fingerprint: "base-fingerprint", source: :private_host_base}
             )

    assert_received {:delta_bytes, "delta-bytes"}
    assert_received {:root_bytes, "converted-root"}
    assert_receive {:delta_call, _, request}
    assert_receive {:delta_cleanup, id, :completed}
    assert id == request.call_id
    assert is_integer(request.deadline)
    assert download_paths(fixture) == ["/images/delta.vcdiff"]
    refute inspect(client) =~ "adapter-private"
  end

  test "missing optional adapter/base/delta uses full files without conversion", %{
    identity: identity
  } do
    {client, fixture} = download_client(identity, "metadata", "root", delta: "delta")
    base = %{fingerprint: "base-fingerprint", source: :host_base}
    sink = fn _ -> :ok end

    assert {:ok, _} =
             SimpleStreams.image_file(client, "image-fingerprint", %{rootfs: sink},
               delta_base: base
             )

    client = with_delta(client, delta_config(fn _, _ -> flunk("unexpected conversion") end))
    assert {:ok, _} = SimpleStreams.image_file(client, "image-fingerprint", %{rootfs: sink})

    assert {:ok, _} =
             SimpleStreams.image_file(client, "image-fingerprint", %{rootfs: sink},
               delta_base: %{base | fingerprint: "not-cached"}
             )

    assert download_paths(fixture) == List.duplicate("/images/root.squashfs", 3)
    refute_received {:delta_call, _, _}

    assert_raise ArgumentError, fn ->
      SimpleStreams.new!(client.connection, client.context,
        architecture: "x86_64",
        delta_adapter: String,
        delta_config: nil
      )
    end
  end

  for failure <- [:wrong_bytes, :ignored_rejection, :repeat_download, :foreign_emitter] do
    test "delta #{failure} fails visibly, cleans its call and never falls back/replays", %{
      identity: identity
    } do
      {client, fixture} = download_client(identity, "metadata", "root", delta: "delta")
      parent = self()

      client =
        with_delta(
          client,
          delta_config(fn request, emit ->
            assert {:ok, _} = request.download_delta.(fn _ -> :ok end)
            delta_failure(unquote(failure), request, emit)
          end)
        )

      sink = fn bytes ->
        send(parent, {:emitted, bytes})
        :ok
      end

      assert {:error, %Error{kind: :delta_failed, response: %{fingerprint: "image-fingerprint"}}} =
               SimpleStreams.image_file(client, "image-fingerprint", %{rootfs: sink},
                 delta_base: %{fingerprint: "base-fingerprint", source: :host_base}
               )

      assert_receive {:delta_call, _, request}
      assert_receive {:delta_cleanup, id, :failed}
      assert id == request.call_id
      assert download_paths(fixture) == ["/images/delta.vcdiff"]
      if unquote(failure) != :wrong_bytes, do: refute_received({:emitted, _})
    end
  end

  defp delta_failure(:wrong_bytes, _, emit), do: emit.("bad!")

  defp delta_failure(:ignored_rejection, _, emit) do
    assert {:error, _} = emit.("too-long")
    assert {:error, _} = emit.("root")
    :ok
  end

  defp delta_failure(:repeat_download, request, emit) do
    assert {:error, _} = request.download_delta.(fn _ -> :ok end)
    assert {:error, _} = emit.("root")
    :ok
  end

  defp delta_failure(:foreign_emitter, _, emit) do
    assert {:error, _} = Task.async(fn -> emit.("root") end) |> Task.await()
    assert {:error, _} = emit.("root")
    :ok
  end

  for cause <- [:deadline, :owner_loss] do
    test "delta #{cause} kills exit-trapping conversion and invokes unique bounded cleanup", %{
      identity: identity
    } do
      {client, fixture} = download_client(identity, "metadata", "root", delta: "delta")
      parent = self()

      client =
        with_delta(
          client,
          delta_config(fn _, _ ->
            Process.flag(:trap_exit, true)
            send(parent, {:converting, self()})

            receive do
              :never -> :ok
            end
          end)
        )

      client = %{client | connection: %{client.connection | stream_timeout: 100}}

      owner =
        spawn(fn ->
          result =
            SimpleStreams.image_file(
              client,
              "image-fingerprint",
              %{rootfs: fn _ -> flunk("unexpected output") end},
              delta_base: %{fingerprint: "base-fingerprint", source: :host_base}
            )

          send(parent, {:delta_result, result})
        end)

      on_exit(fn -> if Process.alive?(owner), do: Process.exit(owner, :kill) end)
      assert_receive {:converting, worker}, 1_000
      assert_receive {:delta_call, ^worker, request}
      monitor = Process.monitor(worker)
      if unquote(cause) == :owner_loss, do: Process.exit(owner, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 500
      expected = if unquote(cause) == :deadline, do: :deadline, else: :owner_lost
      assert_receive {:delta_cleanup, id, ^expected}, 500
      assert id == request.call_id

      if unquote(cause) == :deadline,
        do: assert_receive({:delta_result, {:error, %Error{kind: :deadline}}}, 500)

      assert download_paths(fixture) == []
    end
  end

  test "delta cleanup failure preserves its primary result and image identity", %{
    identity: identity
  } do
    {client, fixture} = download_client(identity, "metadata", "root", delta: "delta")

    config =
      delta_config(fn request, emit ->
        assert {:ok, _} = request.download_delta.(fn _ -> :ok end)
        :ok = emit.("root")
        :ok
      end)
      |> Map.put(:cleanup, fn _, _ -> {:error, :host_cleanup_failed} end)

    client = with_delta(client, config)

    assert {:error,
            %Error{
              kind: :adapter_cleanup,
              response: %{fingerprint: "image-fingerprint", error: error}
            }} =
             SimpleStreams.image_file(client, "image-fingerprint", %{rootfs: fn _ -> :ok end},
               delta_base: %{fingerprint: "base-fingerprint", source: :host_base}
             )

    assert {:ok, %{size: 4}} = error.response
    assert download_paths(fixture) == ["/images/delta.vcdiff"]
  end

  test "configured delta construction is passive and unauthorized calls never convert", %{
    identity: identity
  } do
    {client, fixture} = download_client(identity, "metadata", "root", delta: "delta")
    count = length(HTTPFixture.requests(fixture))

    configured =
      SimpleStreams.new!(client.connection, client.context,
        architecture: "x86_64",
        delta_adapter: DeltaAdapter,
        delta_config: delta_config(fn _, _ -> flunk("unauthorized conversion") end)
      )

    assert configured.catalog == nil
    assert length(HTTPFixture.requests(fixture)) == count

    configured = %{
      configured
      | catalog: client.catalog,
        context: %{client.context | ready?: fn -> false end}
    }

    assert {:error, %Error{kind: :host_not_ready}} =
             SimpleStreams.image_file(configured, "image-fingerprint", %{rootfs: fn _ -> :ok end},
               delta_base: %{fingerprint: "base-fingerprint", source: :host_base}
             )

    refute_received {:delta_call, _, _}
    assert length(HTTPFixture.requests(fixture)) == count
  end

  test "corrupt delta prevents output, cleans resources and preserves its checksum failure", %{
    identity: identity
  } do
    {client, fixture} =
      download_client(identity, "metadata", "root", delta: "delta", corrupt: true)

    client =
      with_delta(
        client,
        delta_config(fn request, _ -> request.download_delta.(fn _ -> :ok end) end)
      )

    assert {:error, %Error{kind: :checksum, response: %{fingerprint: "image-fingerprint"}}} =
             SimpleStreams.image_file(
               client,
               "image-fingerprint",
               %{rootfs: fn _ -> flunk("corrupt delta emitted output") end},
               delta_base: %{fingerprint: "base-fingerprint", source: :host_base}
             )

    assert_receive {:delta_cleanup, _, :failed}
    assert download_paths(fixture) == ["/images/delta.vcdiff"]
  end

  test "delta output rejection remains sticky and converted bytes never exceed their aggregate budget",
       %{identity: identity} do
    {client, fixture} = download_client(identity, "metadata", "root", delta: "delta")

    config =
      delta_config(fn request, emit ->
        assert {:ok, _} = request.download_delta.(fn _ -> :ok end)
        assert {:error, _} = emit.("root")
        assert {:error, _} = emit.("root")
        :ok
      end)

    client = with_delta(client, config)
    owner = self()

    sink = fn _ ->
      send(owner, :sink_called)
      {:error, :closed}
    end

    assert {:error, %Error{kind: :delta_failed}} =
             SimpleStreams.image_file(client, "image-fingerprint", %{rootfs: sink},
               delta_base: %{fingerprint: "base-fingerprint", source: :host_base}
             )

    assert_received :sink_called
    refute_received :sink_called
    limited = %{client | connection: %{client.connection | max_stream_bytes: 8}}

    assert {:error, %Error{kind: :invalid_download_manifest}} =
             SimpleStreams.image_file(limited, "image-fingerprint", %{rootfs: fn _ -> :ok end},
               delta_base: %{fingerprint: "base-fingerprint", source: :host_base}
             )

    assert download_paths(fixture) == ["/images/delta.vcdiff"]
  end

  defp delta_config(convert),
    do: %{
      owner: self(),
      private: "adapter-private",
      convert: convert,
      cleanup: fn _, _ -> :ok end
    }

  defp with_delta(client, config),
    do: %{client | delta_adapter: DeltaAdapter, delta_config: config}

  defp download_paths(fixture),
    do:
      HTTPFixture.requests(fixture)
      |> Enum.map(& &1.target)
      |> Enum.filter(&String.starts_with?(&1, "/images/"))

  for failure <- [:raise, :throw, :exit] do
    test "caught delta sink #{failure} remains rejected with no further output", %{
      identity: identity
    } do
      {client, fixture} = download_client(identity, "metadata", "root", delta: "delta")

      client =
        with_delta(
          client,
          delta_config(fn request, emit ->
            assert {:ok, _} = request.download_delta.(fn _ -> :ok end)

            try do
              emit.("root")
            rescue
              _ -> :caught
            catch
              _, _ -> :caught
            end

            emit.("root")
            :ok
          end)
        )

      parent = self()
      count = :atomics.new(1, [])

      sink = fn _ ->
        send(parent, :sink_attempt)
        if :atomics.add_get(count, 1, 1) == 1, do: sink_failure(unquote(failure)), else: :ok
      end

      assert {:error, %Error{kind: :delta_failed}} =
               SimpleStreams.image_file(client, "image-fingerprint", %{rootfs: sink},
                 delta_base: %{fingerprint: "base-fingerprint", source: :host_base}
               )

      assert_received :sink_attempt
      refute_received :sink_attempt
      assert_receive {:delta_cleanup, _, :failed}
      assert download_paths(fixture) == ["/images/delta.vcdiff"]
    end
  end

  defp sink_failure(:raise), do: raise("private sink failure")
  defp sink_failure(:throw), do: throw(:private_sink_failure)
  defp sink_failure(:exit), do: exit(:private_sink_failure)

  test "cleanup waits for a nested download sink even if its owner guard is suspended", %{
    root: root,
    identity: identity
  } do
    {client, fixture} = download_client(identity, "metadata", "root", delta: "delta")
    {:ok, state} = Agent.start_link(fn -> nil end)
    parent = self()
    artifact = Path.join(root, "conversion-artifact")

    config =
      delta_config(fn request, _ ->
        request.download_delta.(fn _ ->
          Process.flag(:trap_exit, true)
          worker = self()
          Agent.update(state, fn _ -> worker end)
          send(parent, {:nested_sink, worker})

          receive do
            :late_write -> File.write!(artifact, "must not survive cleanup")
          end

          :ok
        end)
      end)
      |> Map.put(:cleanup, fn _, _ ->
        worker = Agent.get(state, & &1)
        send(parent, {:cleanup_observed_live_sink, Process.alive?(worker)})
        send(worker, :late_write)
        File.rm(artifact)
        :ok
      end)

    client = with_delta(client, config)

    caller =
      spawn(fn ->
        SimpleStreams.image_file(client, "image-fingerprint", %{rootfs: fn _ -> :ok end},
          delta_base: %{fingerprint: "base-fingerprint", source: :host_base}
        )
      end)

    on_exit(fn -> if Process.alive?(caller), do: Process.exit(caller, :kill) end)
    assert_receive {:nested_sink, worker}, 1_000
    {:monitored_by, watchers} = Process.info(worker, :monitored_by)

    guard =
      Enum.find(watchers, fn pid ->
        case Process.info(pid, :current_stacktrace) do
          {:current_stacktrace, stack} ->
            Enum.any?(stack, fn {module, function, _, _} ->
              module == Opsmaru.Incus.Transport and function in [:guard, :guard_until]
            end)

          _ ->
            false
        end
      end)

    assert is_pid(guard)
    :erlang.suspend_process(guard)
    on_exit(fn -> if Process.alive?(guard), do: Process.exit(guard, :kill) end)
    Process.exit(caller, :kill)
    assert_receive {:cleanup_observed_live_sink, false}, 500
    assert_receive {:delta_cleanup, _, :owner_lost}, 500
    refute Process.alive?(worker)
    refute File.exists?(artifact)
    assert download_paths(fixture) == ["/images/delta.vcdiff"]
  end

  test "construction/readiness stays passive and catalogs are connection-local", %{
    identity: identity
  } do
    fixture = fixture(identity, products())
    client = client(HTTPFixture.endpoint(fixture).url, identity, "x86_64")
    refute SimpleStreams.new!(client.connection, client.context, architecture: "amd64").catalog
    assert HTTPFixture.requests(fixture) == []
    not_ready = %{client | context: %{client.context | ready?: fn -> false end}}
    assert {:error, %Error{kind: :host_not_ready}} = SimpleStreams.refresh(not_ready)
    mismatch = %{client | connection: %{client.connection | owner: :other}}
    assert {:error, %Error{kind: :owner_mismatch}} = SimpleStreams.refresh(mismatch)
    assert HTTPFixture.requests(fixture) == []

    assert_raise ArgumentError, fn ->
      SimpleStreams.new!(Connection.unix!("/does/not/exist", owner: :fixture), client.context,
        architecture: "x86_64"
      )
    end

    assert {:ok, next} = SimpleStreams.refresh(client)
    assert {:ok, _} = SimpleStreams.images(next)
    assert {:error, %Error{kind: :catalog_not_loaded}} = SimpleStreams.images(client)
  end

  test "catalog limits and untrusted origins fail visibly without following redirects", %{
    identity: identity
  } do
    fixture = fixture(identity, products())
    client = client(HTTPFixture.endpoint(fixture).url, identity, "x86_64")
    limited = %{client | connection: %{client.connection | queue_limit: 1}}
    assert {:error, %Error{kind: :catalog_limit}} = SimpleStreams.refresh(limited)

    for path <- [
          "https://other.invalid/a",
          "//other.invalid/a",
          "../escape",
          "/%2e%2e/escape",
          "/a%00",
          "/bad%",
          "/a\\b"
        ] do
      assert {:error, %Error{kind: :invalid_path}} = SimpleStreams.path(path)
    end

    wrong = %{
      client
      | connection: %{
          client.connection
          | tls: Keyword.put(client.connection.tls, :fingerprint, String.duplicate("0", 64))
        }
    }

    assert {:error, %Error{kind: :connection}} = SimpleStreams.refresh(wrong)
  end

  defp assert_alias({:ok, model}, value), do: assert(Model.encode(model) == value["alias"])

  defp assert_alias({:error, %Error{message: message}}, value),
    do: assert(message == value["error"])

  defp assert_architectures({:ok, aliases}, value),
    do:
      assert(
        Map.new(aliases, fn {arch, model} -> {arch, Model.encode(model)} end) ==
          value["architectures"]
      )

  defp assert_architectures({:error, %Error{message: message}}, value),
    do: assert(message == value["architecture_error"])

  defp client(url, identity, architecture) do
    connection =
      Connection.https!(url,
        owner: :fixture,
        tls: [cacertfile: identity.cafile, certfile: identity.certfile, keyfile: identity.keyfile]
      )

    context = Context.new!(owner: :fixture, identity: :verified, ready?: fn -> true end)
    SimpleStreams.new!(connection, context, architecture: architecture)
  end

  defp fixture(identity, products) do
    index = %{
      "index" => %{
        "ignored" => %{"datatype" => "other"},
        "images" => %{
          "datatype" => "image-downloads",
          "path" => "streams/v1/images.json",
          "products" => Map.keys(products)
        }
      }
    }

    start_supervised!(
      {HTTPFixture,
       transport: :ssl,
       certfile: identity.certfile,
       keyfile: identity.keyfile,
       handler: fn request ->
         data =
           case request.target do
             "/streams/v1/index.json" -> index
             "/streams/v1/images.json" -> %{"products" => products}
           end

         %{
           status: 200,
           body: data,
           headers: [{"content-type", "application/json"}]
         }
       end}
    )
  end

  defp oracle(root, url, identity) do
    input = Path.join(root, "oracle.json")

    File.write!(
      input,
      Jason.encode!(%{
        URL: url,
        Certificate: File.read!(identity.certfile),
        Names: ["fixture", "missing", "fixture/amd64"],
        Fingerprints: ["aaaa", "aa", "missing"]
      })
    )

    {out, status} =
      System.cmd("sh", ["-c", "exec \"$1\" < \"$2\"", "oracle", @driver, input],
        stderr_to_stdout: true
      )

    assert status == 0, out
    Jason.decode!(out)
  end

  defp products do
    for arch <- ~w(amd64 arm64), into: %{} do
      versions =
        for {serial, hash} <- [{"20260101", "aaaa"}, {"20261001", "aabb"}], into: %{} do
          metadata = %{
            "ftype" => "incus.tar.xz",
            "path" => "images/meta.tar.xz",
            "sha256" => "meta",
            "size" => 11,
            "combined_squashfs_sha256" => hash <> arch,
            "combined_disk-kvm-img_sha256" => "vm" <> hash <> arch
          }

          root = %{
            "ftype" => "squashfs",
            "path" => "images/root.squashfs",
            "sha256" => "root",
            "size" => 23
          }

          vm = %{
            "ftype" => "disk-kvm.img",
            "path" => "images/root.img",
            "sha256" => "vmroot",
            "size" => 31
          }

          {serial,
           %{"label" => "default", "items" => %{"meta" => metadata, "root" => root, "vm" => vm}}}
        end

      {arch,
       %{
         "arch" => arch,
         "os" => "Fixture",
         "release" => "stable",
         "release_title" => "Stable",
         "version" => "1",
         "variant" => "default",
         "aliases" => "fixture",
         "requirements" => %{"secureboot" => "false"},
         "support_eol" => "2030-01-01",
         "versions" => versions
       }}
    end
  end
end
