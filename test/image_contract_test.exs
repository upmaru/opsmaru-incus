defmodule Opsmaru.Incus.ImageContractTest do
  @moduledoc "S05 image uploads and downloads compared with the pinned CreateImage and GetImageFile."
  use ExUnit.Case, async: false
  alias Opsmaru.Incus
  alias Opsmaru.Incus.{Connection, Context, Error, Images, Server}
  alias Opsmaru.TestSupport.{HTTPFixture, TLSIdentity}
  @driver Path.expand("../.integration/image-contract-driver", __DIR__)
  @extensions ~w(image_compression_algorithm images_push_relay)
  @metadata :binary.copy(<<0, 255, 128, 13, 10>>, 64)
  @rootfs :binary.copy(<<255, 0, 128, 1>>, 96)

  setup_all do
    File.mkdir_p!(Path.dirname(@driver))

    {out, status} =
      System.cmd("mise", ["exec", "--", "go", "build", "-o", @driver, "."],
        cd: Path.expand("reference", __DIR__),
        env: [{"GOTOOLCHAIN", "local"}],
        stderr_to_stdout: true
      )

    assert status == 0, out
    :ok
  end

  setup do
    root = Path.join(System.tmp_dir!(), "op-image-contract-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  for transport <- [:unix, :https] do
    test "#{transport} S05 uploads agree with the pinned CreateImage", %{root: root} do
      identity = identity(root, unquote(transport))

      # Unified, split container (`rootfs`) and split virtual machine (`rootfs.img`).
      for {rootfs, type} <- [{nil, nil}, {@rootfs, "container"}, {@rootfs, "virtual-machine"}],
          image <- images(),
          outcome <- [:accepted, 400, :lost] do
        native = backend(root, identity, fn _ -> upload_reply(outcome) end)

        expected =
          driver(
            root,
            Map.merge(oracle(native, identity), %{
              transfer: "import_image",
              payload: Base.encode64(@metadata),
              rootfs: rootfs && Base.encode64(rootfs),
              body: image,
              image_type: type
            })
          )

        [native_request] = posts(native)
        fixture = backend(root, identity, fn _ -> upload_reply(outcome) end)
        opts = if rootfs, do: [rootfs: [rootfs], type: type], else: []
        actual = Images.import(client(fixture, identity), image, [@metadata], opts)

        # One upload each; a lost reply is never resent.
        assert [request] = posts(fixture)
        assert request.target == native_request.target

        for key <-
              ~w(x-incus-public x-incus-filename x-incus-properties x-incus-profiles x-incus-aliases x-incus-fingerprint x-incus-secret),
            do: assert(request.headers[key] == native_request.headers[key], key)

        if rootfs do
          assert "multipart/form-data; boundary=" <> _ = request.headers["content-type"]
          assert parts(native_request) == parts(request)

          assert [{"metadata", "metadata.tar", @metadata}, {name, "rootfs.tar", @rootfs}] =
                   parts(request)

          assert name == if(type == "virtual-machine", do: "rootfs.img", else: "rootfs")
        else
          assert request.headers["content-type"] == native_request.headers["content-type"]
          assert request.body == native_request.body and request.body == @metadata
        end

        case outcome do
          :accepted ->
            refute expected["error"]
            assert expected["operation"]["id"] == "image-op"
            assert {:ok, %{type: "async", operation: "/1.0/operations/image-op"}} = actual

          400 ->
            assert {:error, %Error{kind: :native, http_status: 400, message: message}} = actual
            assert expected["error"] == message

          :lost ->
            assert expected["error"]
            assert {:error, %Error{kind: :uncertain}} = actual
        end
      end

      # A compressed upload needs image_compression_algorithm; both reject before sending.
      native = backend(root, identity, fn _ -> flunk("guarded upload was dispatched") end, [])

      expected =
        driver(
          root,
          Map.merge(oracle(native, identity), %{
            transfer: "import_image",
            payload: Base.encode64(@metadata),
            body: %{"compression_algorithm" => "zstd"}
          })
        )

      assert expected["error"] =~ "image_compression_algorithm"
      fixture = backend(root, identity, fn _ -> flunk("guarded upload was dispatched") end, [])

      assert {:error,
              %Error{kind: :unsupported_extension, extension: "image_compression_algorithm"}} =
               Images.import(
                 client(fixture, identity, []),
                 %{"compression_algorithm" => "zstd"},
                 [
                   @metadata
                 ]
               )

      assert posts(native) == [] and posts(fixture) == []
    end

    test "#{transport} S05 downloads agree with the pinned GetImageFile", %{root: root} do
      identity = identity(root, unquote(transport))

      for {name, reply, fingerprint, sinks} <- downloads() do
        native = backend(root, identity, fn _ -> reply end)

        expected =
          driver(
            root,
            Map.merge(oracle(native, identity), %{
              transfer: "download_image",
              fingerprint: fingerprint,
              meta_only: sinks == [:metadata]
            })
          )

        [native_request] = gets(native)
        fixture = backend(root, identity, fn _ -> reply end)

        capture =
          start_supervised!({Agent, fn -> %{metadata: [], rootfs: []} end}, id: make_ref())

        actual =
          Images.download(
            client(fixture, identity),
            fingerprint,
            Map.new(sinks, &{&1, fn bytes -> Agent.update(capture, sink(&1, bytes)) end})
          )

        # One export each, with the pinned path and routing query.
        assert [request] = gets(fixture)
        assert request.target == native_request.target

        written =
          Agent.get(
            capture,
            &Map.new(&1, fn {k, v} -> {k, IO.iodata_to_binary(Enum.reverse(v))} end)
          )

        case {name, actual} do
          {_, {:ok, transfer}} when name in [:unified, :container, :vm, :oci] ->
            refute expected["error"], inspect({name, expected})
            response = expected["response"]
            assert written.metadata == Base.decode64!(expected["metadata"])
            assert written.rootfs == Base.decode64!(expected["rootfs"])
            assert transfer.result.names.metadata == response["MetaName"]

            assert transfer.result.names[:rootfs] ==
                     if(response["RootfsName"] != "", do: response["RootfsName"])

            assert transfer.result.sizes == %{
                     metadata: response["MetaSize"],
                     rootfs: response["RootfsSize"]
                   }

          {:native, {:error, %Error{kind: :native, http_status: 404, message: message}}} ->
            assert expected["error_status"] == 404 and expected["error"] == message

          # A split export with one sink is refused before any byte is written.
          {:meta_only, {:error, %Error{}}} ->
            assert expected["error"] =~ "only one target file"
            assert written == %{metadata: "", rootfs: ""}

          {failure, {:error, %Error{}}} when failure in [:mismatch, :no_filename, :bad_part] ->
            assert expected["error"], inspect({name, expected})
        end
      end
    end
  end

  # Every upload header: public, filename, properties, profiles and aliases; a push
  # target's fingerprint and secret; a compression algorithm; and no options at all.
  defp images,
    do: [
      %{
        "public" => true,
        "filename" => "fixture image.tar",
        "properties" => %{"os" => "fixture", "architecture" => "aarch64"},
        "profiles" => ["default", "fixture"],
        "aliases" => [%{"name" => "fixture-one"}, %{"name" => "fixture two"}]
      },
      %{
        "source" => %{
          "mode" => "push",
          "fingerprint" => "fixture-fingerprint",
          "secret" => "s+/="
        }
      },
      %{"compression_algorithm" => "zstd"},
      %{}
    ]

  defp upload_reply(:accepted),
    do: %{
      status: 202,
      body: %{
        type: "async",
        status_code: 100,
        operation: "/1.0/operations/image-op",
        metadata: %{id: "image-op", class: "task", status: "Running", status_code: 103}
      }
    }

  defp upload_reply(:lost), do: %{raw: ""}

  defp upload_reply(code),
    do: %{status: code, body: %{type: "error", error_code: code, error: "native image rejection"}}

  # Unified, split container and virtual-machine, and OCI exports; a fingerprint
  # mismatch, a split export with one sink, a unified export without a filename, a
  # misordered split export and a native error.
  defp downloads do
    unified = fingerprint(@metadata)
    split = fingerprint(@metadata <> @rootfs)

    [
      {:unified, export(@metadata, filename: "fixture.tar.xz"), unified, [:metadata, :rootfs]},
      {:container, export(split_body("rootfs"), split: true), split, [:metadata, :rootfs]},
      {:vm, export(split_body("rootfs.img"), split: true), split, [:metadata, :rootfs]},
      {:oci, export(@metadata, filename: "oci.tar", oci: true), String.duplicate("0", 64),
       [:metadata, :rootfs]},
      {:mismatch, export(@metadata, filename: "fixture.tar"), String.duplicate("0", 64),
       [:metadata, :rootfs]},
      {:meta_only, export(split_body("rootfs"), split: true), split, [:metadata]},
      {:no_filename, export(@metadata, []), unified, [:metadata, :rootfs]},
      {:bad_part, export(misordered_body(), split: true), split, [:metadata, :rootfs]},
      {:native, %{status: 404, body: %{type: "error", error_code: 404, error: "not found"}},
       unified, [:metadata, :rootfs]}
    ]
  end

  defp export(body, opts) do
    headers =
      [
        {"Content-Length", byte_size(body)},
        {"Content-Type",
         if(opts[:split],
           do: "multipart/form-data; boundary=fixture-export",
           else: "application/octet-stream"
         )}
      ] ++
        if(opts[:filename],
          do: [{"Content-Disposition", ~s(attachment; filename="#{opts[:filename]}")}],
          else: []
        ) ++ if(opts[:oci], do: [{"X-Incus-Type", "oci"}], else: [])

    head = Enum.map_join(headers, "", fn {key, value} -> "#{key}: #{value}\r\n" end)
    %{raw: "HTTP/1.1 200 OK\r\n" <> head <> "\r\n" <> body}
  end

  defp split_body(rootfs),
    do: part("metadata", "meta.tar", @metadata) <> part(rootfs, "root.img", @rootfs) <> close()

  defp misordered_body,
    do: part("rootfs", "root.img", @rootfs) <> part("metadata", "meta.tar", @metadata) <> close()

  defp part(name, filename, bytes),
    do:
      ~s(--fixture-export\r\nContent-Disposition: form-data; name="#{name}"; filename="#{filename}"\r\nContent-Type: application/octet-stream\r\n\r\n) <>
        bytes <> "\r\n"

  defp close, do: "--fixture-export--\r\n"

  defp fingerprint(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  defp sink(kind, bytes), do: &Map.update!(&1, kind, fn chunks -> [bytes | chunks] end)

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

        part =
          {elem(List.keyfind(params, "name", 0), 1), elem(List.keyfind(params, "filename", 0), 1),
           bytes}

        parts(rest, boundary, [part | acc])

      {:done, _} ->
        Enum.reverse(acc)
    end
  end

  defp posts(fixture), do: Enum.filter(HTTPFixture.requests(fixture), &(&1.method == "POST"))

  defp gets(fixture),
    do:
      Enum.filter(
        HTTPFixture.requests(fixture),
        &(&1.method == "GET" and URI.parse(&1.target).path != "/1.0")
      )

  defp backend(root, identity, handler, extensions \\ @extensions) do
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
          path: Path.join(root, "image-#{System.unique_integer([:positive])}")
        ]

    discovery = %{
      status: 200,
      body: %{
        type: "sync",
        metadata: %{
          api_version: "1.0",
          auth: "trusted",
          api_extensions: extensions,
          environment: %{}
        }
      }
    }

    handler = fn request ->
      if URI.parse(request.target).path == "/1.0", do: discovery, else: handler.(request)
    end

    start_supervised!({HTTPFixture, options ++ [handler: handler]}, id: make_ref())
  end

  defp client(fixture, identity, extensions \\ @extensions) do
    endpoint = HTTPFixture.endpoint(fixture)
    opts = [owner: :fixture, project: "fixture scope", member: "member/a", timeout: 5_000]

    connection =
      if identity,
        do:
          Connection.https!(
            endpoint.url,
            opts ++
              [
                tls: [
                  cacertfile: identity.cafile,
                  certfile: identity.certfile,
                  keyfile: identity.keyfile
                ]
              ]
          ),
        else: Connection.unix!(endpoint.socket, opts)

    %Incus{
      connection: connection,
      context: Context.new!(owner: :fixture, identity: :verified, ready?: fn -> true end),
      server: %Server{api_extensions: extensions}
    }
  end

  defp oracle(fixture, nil),
    do: %{
      socket: HTTPFixture.endpoint(fixture).socket,
      project: "fixture scope",
      target: "member/a"
    }

  defp oracle(fixture, identity),
    do: %{
      url: HTTPFixture.endpoint(fixture).url,
      tls_ca: File.read!(identity.cafile),
      client_cert: File.read!(identity.certfile),
      client_key: File.read!(identity.keyfile),
      project: "fixture scope",
      target: "member/a"
    }

  defp identity(_root, :unix), do: nil
  defp identity(root, :https), do: TLSIdentity.generate(root, "image-contract", "localhost")

  defp driver(root, input) do
    file = Path.join(root, "image-#{System.unique_integer([:positive])}.json")
    File.write!(file, Jason.encode!(input))
    File.chmod!(file, 0o600)
    {out, status} = System.cmd(@driver, [file], stderr_to_stdout: true)
    assert status == 0, out
    Jason.decode!(out)
  end
end
