defmodule Opsmaru.Incus.SimpleStreamsTest do
  use ExUnit.Case, async: false
  alias Opsmaru.Context
  alias Opsmaru.Incus.{Connection, Error, Model, SimpleStreams}
  alias Opsmaru.TestSupport.{HTTPFixture, TLSIdentity}
  @driver Path.expand("../../.integration/simplestreams-driver", __DIR__)

  setup_all do
    File.mkdir_p!(Path.dirname(@driver))

    {out, status} =
      System.cmd("mise", ["exec", "--", "go", "build", "-o", @driver, "./simplestreams"],
        cd: Path.expand("../reference", __DIR__),
        env: [{"GOTOOLCHAIN", "local"}],
        stderr_to_stdout: true
      )

    assert status == 0, out
    :ok
  end

  setup do
    root = Path.join(System.tmp_dir!(), "op-ss-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    identity = TLSIdentity.generate(root, "ss", "localhost")
    %{root: root, identity: identity}
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
    assert length(HTTPFixture.requests(fixture)) == 4
    assert {:error, %Error{kind: :catalog_not_loaded}} = SimpleStreams.images(client)
    refute inspect(client) =~ root
    assert {:ok, next} = SimpleStreams.refresh(client)
    assert client.catalog == nil
    assert_native_catalog(next, expected)
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
      client = %{client | connection: %{client.connection | stream_timeout: 100}}
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
      assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 500

      if unquote(cause) == :deadline,
        do: assert_receive({:download_result, {:error, %Error{kind: :deadline}}}, 500)

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
               bytes = if path == "/images/meta.tar.xz", do: metadata, else: rootfs
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

  defp hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

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
