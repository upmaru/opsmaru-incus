defmodule Opsmaru.Incus.ImageTransferTest do
  use ExUnit.Case, async: false
  alias Opsmaru.{Context, Incus}
  alias Opsmaru.Incus.{Connection, Error, Images, Model}
  alias Opsmaru.TestSupport.{HTTPFixture, TLSIdentity}
  @driver Path.expand("../.integration/incus-image-driver", __DIR__)

  setup_all do
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
    root = Path.join(System.tmp_dir!(), "op-image-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)

    %{
      root: root,
      context: Context.new!(owner: :fixture, identity: :verified, ready?: fn -> true end)
    }
  end

  for secret <- [nil, 42, %{"bad" => true}] do
    test "malformed accepted image token #{inspect(secret)} retains uncertainty in direct and private copy helpers",
         %{root: root, context: context} do
      secret = unquote(Macro.escape(secret))
      identity = TLSIdentity.generate(root, "bad-secret", "localhost")

      accepted = %{
        status: 202,
        body: %{
          type: "async",
          status_code: 100,
          operation: "/1.0/operations/token-op",
          metadata: %{id: "token-op", status_code: 103, metadata: %{secret: secret}}
        }
      }

      fixture = tls_backend(identity, fn _ -> accepted end)
      source = tls_client(fixture, identity, context)
      target_fixture = backend(root, fn _ -> flunk("target mutation must not occur") end)
      target = client(target_fixture, context)

      for result <- [
            Images.image_secret(source, "fingerprint"),
            Images.copy(target, source, %{"fingerprint" => "fingerprint", "public" => false},
              mode: "pull"
            )
          ] do
        assert {:error,
                %Error{
                  kind: :uncertain,
                  operation: "/1.0/operations/token-op",
                  response: response
                }} = result

        assert response.type == "async"
        assert response.operation == "/1.0/operations/token-op"
        assert response.metadata.data["metadata"]["secret"] == secret
        assert response.connection == source.connection
        assert response.identity == context.identity
      end

      assert Enum.count(HTTPFixture.requests(fixture), &(&1.method == "POST")) == 2
      assert [%{method: "GET", target: "/1.0"}] = HTTPFixture.requests(target_fixture)
    end
  end

  for split <- [false, true] do
    test "official unified/split image upload/download agrees (split=#{split})", %{
      root: root,
      context: context
    } do
      split = unquote(split)
      metadata = :binary.copy(<<0, 255, 128, 13, 10>>, 100)
      rootfs = if split, do: :binary.copy(<<255, 0, 128, 1>>, 200), else: nil

      image = %{
        "public" => true,
        "filename" => "native.img",
        "properties" => %{"os" => "fixture", "architecture" => "aarch64"},
        "profiles" => ["one", "two"],
        "aliases" => [%{"name" => "native"}]
      }

      accepted = %{
        status: 202,
        body: %{
          type: "async",
          status_code: 100,
          operation: "/1.0/operations/image-id",
          metadata: %{id: "image-id", status_code: 103}
        }
      }

      oracle = backend(root, fn _ -> accepted end)

      result =
        driver(root, %{
          socket: HTTPFixture.endpoint(oracle).socket,
          transfer: "import_image",
          payload: Base.encode64(metadata),
          rootfs: if(rootfs, do: Base.encode64(rootfs)),
          body: image,
          image_type: "virtual-machine"
        })

      refute result["error"]
      native_request = HTTPFixture.requests(oracle) |> List.last()
      fixture = backend(root, fn _ -> accepted end)
      client = client(fixture, context)
      opts = if rootfs, do: [rootfs: [rootfs], type: "virtual-machine"], else: []
      assert {:ok, response} = Images.import(client, image, [metadata], opts)
      assert response.operation == "/1.0/operations/image-id"
      request = HTTPFixture.requests(fixture) |> List.last()
      assert URI.parse(request.target).path == URI.parse(native_request.target).path

      for key <- [
            "x-incus-public",
            "x-incus-filename",
            "x-incus-properties",
            "x-incus-profiles",
            "x-incus-aliases"
          ],
          do: assert(request.headers[key] == native_request.headers[key])

      if split do
        assert multipart(native_request) == multipart(request)
      else
        assert native_request.body == request.body
        assert request.body == metadata
      end

      fingerprint = Base.encode16(:crypto.hash(:sha256, metadata <> (rootfs || "")), case: :lower)
      # Reuse official multipart bytes as independent input, fragmenting through
      # every header/body boundary with a 3-byte client sink chunk budget.
      body = native_request.body
      content_type = native_request.headers["content-type"]

      headers =
        "HTTP/1.1 200 OK\r\nContent-Type: #{content_type}\r\nContent-Disposition: attachment; filename=\"metadata.tar\"\r\nContent-Length: #{byte_size(body)}\r\n\r\n"

      download_oracle = backend(root, fn _ -> %{raw: headers <> body} end)

      result =
        driver(root, %{
          socket: HTTPFixture.endpoint(download_oracle).socket,
          transfer: "download_image",
          fingerprint: fingerprint
        })

      refute result["error"]
      assert Base.decode64!(result["metadata"]) == metadata
      assert Base.decode64!(result["rootfs"]) == (rootfs || "")
      download_fixture = backend(root, fn _ -> %{raw: headers <> body} end)
      client = client(download_fixture, context)
      client = %{client | connection: %{client.connection | max_chunk_bytes: 3}}
      {:ok, capture} = Agent.start_link(fn -> %{metadata: [], rootfs: []} end)
      on_exit(fn -> if Process.alive?(capture), do: Agent.stop(capture) end)

      sinks =
        Map.new([:metadata, :rootfs], fn kind ->
          {kind,
           fn data ->
             Agent.update(capture, &Map.update!(&1, kind, fn old -> [data | old] end))
           end}
        end)

      assert {:ok, transfer} = Images.download(client, fingerprint, sinks)
      assert transfer.result.sha256 == fingerprint
      assert transfer.result.sizes.metadata == byte_size(metadata)
      assert transfer.result.sizes.rootfs == byte_size(rootfs || "")

      assert Agent.get(capture, fn chunks ->
               chunks.metadata |> Enum.reverse() |> IO.iodata_to_binary()
             end) == metadata

      assert Agent.get(capture, fn chunks ->
               chunks.rootfs |> Enum.reverse() |> IO.iodata_to_binary()
             end) == (rootfs || "")
    end
  end

  for mode <- ["pull", "push"], failure <- [:lost, :malformed] do
    test "#{mode} copy #{failure} mutation preserves uncertainty and both known native handles",
         %{
           root: root,
           context: context
         } do
      assert_copy_uncertainty(root, context, unquote(mode), unquote(failure))
    end
  end

  defp assert_copy_uncertainty(root, context, mode, failure) do
    source_identity = TLSIdentity.generate(root, "copy-source", "localhost")
    target_identity = TLSIdentity.generate(root, "copy-target", "localhost")

    accepted = fn id ->
      %{
        status: 202,
        body: %{
          type: "async",
          status_code: 100,
          operation: "/1.0/operations/" <> id,
          metadata: %{id: id, status_code: 103, metadata: %{secret: "private-token"}}
        }
      }
    end

    failing =
      if failure == :lost,
        do: %{raw: ""},
        else: %{
          status: 202,
          body: %{
            type: "async",
            status_code: 100,
            operation: "/1.0/operations/possibly-accepted",
            metadata: [42]
          }
        }

    source_fixture =
      tls_backend(source_identity, fn _ ->
        if mode == "pull", do: accepted.("source-token"), else: failing
      end)

    target_fixture =
      tls_backend(target_identity, fn _ ->
        if mode == "push", do: accepted.("target-token"), else: failing
      end)

    source = tls_client(source_fixture, source_identity, context)
    target = tls_client(target_fixture, target_identity, context)

    assert {:error, %Error{kind: :uncertain, response: state, operation: primary}} =
             Images.copy(target, source, %{"fingerprint" => "native", "public" => false},
               mode: mode
             )

    assert %Error{kind: :uncertain} = state.error
    known = state[if(mode == "pull", do: :source, else: :target)]
    expected = if mode == "pull", do: source, else: target

    assert known.operation ==
             "/1.0/operations/" <> if(mode == "pull", do: "source-token", else: "target-token")

    assert known.connection == expected.connection and known.identity == context.identity

    if failure == :malformed do
      assert primary == "/1.0/operations/possibly-accepted"
      assert state.error.operation == primary
      assert state.error.response.operation == primary
      expected = if mode == "pull", do: target, else: source
      assert state.error.response.connection == expected.connection
    else
      assert primary == known.operation and state.error.operation == nil
    end

    assert Enum.count(HTTPFixture.requests(source_fixture), &(&1.method == "POST")) == 1
    assert Enum.count(HTTPFixture.requests(target_fixture), &(&1.method == "POST")) == 1
    refute inspect(state.error) =~ "private-token"
  end

  for token_metadata <- [%{"secret" => nil}, %{"secret" => 42}, 42] do
    test "accepted push token #{inspect(token_metadata)} is uncertain and never exported", %{
      root: root,
      context: context
    } do
      token_metadata = unquote(Macro.escape(token_metadata))
      source_identity = TLSIdentity.generate(root, "bad-push-source", "localhost")
      target_identity = TLSIdentity.generate(root, "bad-push-target", "localhost")

      source_fixture =
        tls_backend(source_identity, fn _ -> flunk("source export must not occur") end)

      target_fixture =
        tls_backend(target_identity, fn _ ->
          %{
            status: 202,
            body: %{
              type: "async",
              status_code: 100,
              operation: "/1.0/operations/accepted-push-token",
              metadata: %{id: "accepted-push-token", status_code: 103, metadata: token_metadata}
            }
          }
        end)

      source = tls_client(source_fixture, source_identity, context)
      target = tls_client(target_fixture, target_identity, context)

      assert {:error, %Error{kind: :uncertain, response: accepted, operation: operation}} =
               Images.copy(target, source, %{"fingerprint" => "native", "public" => true},
                 mode: "push"
               )

      assert operation == "/1.0/operations/accepted-push-token"
      assert accepted.operation == operation and accepted.connection == target.connection
      assert Model.encode(accepted.metadata)["metadata"] == token_metadata
      assert Enum.count(HTTPFixture.requests(target_fixture), &(&1.method == "POST")) == 1
      assert Enum.all?(HTTPFixture.requests(source_fixture), &(&1.method == "GET"))
    end
  end

  test "fingerprint mismatch is explicit and does not delete source or destination data", %{
    root: root,
    context: context
  } do
    fixture =
      backend(root, fn _ ->
        %{
          raw:
            "HTTP/1.1 200 OK\r\nContent-Length: 3\r\nContent-Disposition: attachment; filename=\"native.img\"\r\n\r\nabc"
        }
      end)

    assert {:error, %Error{kind: :fingerprint_mismatch}} =
             Images.download(client(fixture, context), String.duplicate("0", 64), %{
               metadata: fn _ -> :ok end
             })

    assert length(HTTPFixture.requests(fixture)) == 2
  end

  test "pull/push copies use approved origins, preserve operations and match official request fields",
       %{root: root, context: context} do
    for mode <- ["pull", "push"] do
      source_identity = TLSIdentity.generate(root, "source-#{mode}", "localhost")
      target_identity = TLSIdentity.generate(root, "target-#{mode}", "localhost")

      accepted = %{
        status: 202,
        body: %{
          type: "async",
          status_code: 100,
          operation: "/1.0/operations/copy-id",
          metadata: %{
            id: "copy-id",
            status_code: 200,
            may_cancel: true,
            metadata: %{secret: "fixture-secret"}
          }
        }
      }

      source_fixture = tls_backend(source_identity, fn _ -> accepted end)
      target_fixture = tls_backend(target_identity, fn _ -> accepted end)

      image = %{
        "fingerprint" => "native-fingerprint",
        "public" => true,
        "type" => "virtual-machine",
        "properties" => %{},
        "expires_at" => "0001-01-01T00:00:00Z"
      }

      result =
        driver(root, %{
          url: HTTPFixture.endpoint(target_fixture).url,
          server_cert: File.read!(target_identity.certfile),
          transfer: "copy_image",
          source_url: HTTPFixture.endpoint(source_fixture).url,
          source_cert: File.read!(source_identity.certfile),
          copy_mode: mode,
          body: image
        })

      refute result["error"]
      oracle_source_requests = HTTPFixture.requests(source_fixture)
      oracle_target_requests = HTTPFixture.requests(target_fixture)
      source = tls_client(source_fixture, source_identity, context)
      target = tls_client(target_fixture, target_identity, context)
      assert {:ok, copied} = Images.copy(target, source, image, mode: mode)
      assert copied.state == :accepted
      assert copied.target.operation == "/1.0/operations/copy-id"
      actual_source = HTTPFixture.requests(source_fixture) |> List.last()
      actual_target = HTTPFixture.requests(target_fixture) |> List.last()
      expected_target = Enum.filter(oracle_target_requests, &(&1.method == "POST")) |> List.last()
      expected_body = Jason.decode!(expected_target.body)
      actual_body = Jason.decode!(actual_target.body)

      assert expected_body["source"]
             |> Map.take(["server", "fingerprint", "mode", "type", "project", "certificate"]) ==
               actual_body["source"]
               |> Map.take(["server", "fingerprint", "mode", "type", "project", "certificate"])

      if mode == "push" do
        expected_source =
          Enum.filter(oracle_source_requests, &(&1.method == "POST")) |> List.last()

        assert Jason.decode!(expected_source.body)
               |> Map.take(["target", "certificate", "secret", "project", "profiles"]) ==
                 Jason.decode!(actual_source.body)
                 |> Map.take(["target", "certificate", "secret", "project", "profiles"])
      end
    end
  end

  test "relay copies use host staging adapters and lost target responses do not delete or replay",
       %{root: root, context: context} do
    bytes = <<0, 255, 128, 13, 10>>
    fingerprint = Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

    source_fixture =
      backend(root, fn _ ->
        %{
          raw: [
            "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nContent-Disposition: attachment; filename=\"native.img\"\r\n\r\n",
            bytes
          ]
        }
      end)

    target_fixture = backend(root, fn _ -> %{raw: ""} end)
    source = client(source_fixture, context)
    target = client(target_fixture, context)
    {:ok, stage} = Agent.start_link(fn -> [] end)
    on_exit(fn -> if Process.alive?(stage), do: Agent.stop(stage) end)

    adapter = %{
      metadata_sink: fn bytes -> Agent.update(stage, &[bytes | &1]) end,
      metadata_source: fn -> Agent.get(stage, &Enum.reverse/1) end
    }

    assert {:error, %Error{kind: :uncertain}} =
             Images.copy(
               target,
               source,
               %{"fingerprint" => fingerprint, "filename" => "native.img", "public" => true},
               mode: "relay",
               relay: adapter
             )

    assert Agent.get(stage, fn chunks -> chunks |> Enum.reverse() |> IO.iodata_to_binary() end) ==
             bytes

    assert length(HTTPFixture.requests(target_fixture)) == 2

    assert {:error, %Error{kind: :same_backend}} =
             Images.copy(source, source, %{"fingerprint" => fingerprint})
  end

  for rootfs <- ["", <<0, 255, 128, 1>>] do
    test "split relay rejects missing rootfs sources before target upload (bytes=#{byte_size(rootfs)})",
         %{root: root, context: context} do
      rootfs = unquote(rootfs)
      metadata = <<128, 0, 255>>
      {raw, fingerprint} = split_export(metadata, rootfs)
      source_fixture = backend(root, fn _ -> %{raw: raw} end)
      target_fixture = backend(root, fn _ -> %{status: 200, body: %{type: "sync"}} end)
      source = client(source_fixture, context)
      target = client(target_fixture, context)
      owner = self()

      for rootfs_source <- [nil, fn _ -> [] end, fn -> nil end] do
        adapter = %{
          metadata_sink: fn bytes ->
            send(owner, {:staged, :metadata, bytes})
            :ok
          end,
          rootfs_sink: fn bytes ->
            send(owner, {:staged, :rootfs, bytes})
            :ok
          end,
          metadata_source: fn ->
            send(owner, :metadata_source_called)
            [metadata]
          end,
          rootfs_source: rootfs_source
        }

        assert {:error, %Error{kind: :missing_relay_adapter}} =
                 Images.copy(target, source, %{"fingerprint" => fingerprint},
                   mode: "relay",
                   relay: adapter
                 )

        refute_received :metadata_source_called
        assert HTTPFixture.requests(target_fixture) |> Enum.map(& &1.method) == ["GET"]
      end

      assert_received {:staged, :metadata, ^metadata}
      assert_received {:staged, :rootfs, ^rootfs}
      assert Enum.all?(HTTPFixture.requests(source_fixture), &(&1.method == "GET"))
    end

    test "split relay preserves both saved parts including empty rootfs (bytes=#{byte_size(rootfs)})",
         %{root: root, context: context} do
      rootfs = unquote(rootfs)
      metadata = <<128, 0, 255>>
      {raw, fingerprint} = split_export(metadata, rootfs)
      source_fixture = backend(root, fn _ -> %{raw: raw} end)

      target_fixture =
        backend(root, fn _ ->
          %{status: 202, body: %{type: "async", operation: "/1.0/operations/split-relay"}}
        end)

      source = client(source_fixture, context)
      target = client(target_fixture, context)
      {:ok, stage} = Agent.start_link(fn -> %{metadata: [], rootfs: []} end)
      on_exit(fn -> if Process.alive?(stage), do: Agent.stop(stage) end)

      adapter =
        Map.new([:metadata, :rootfs], fn kind ->
          {kind,
           fn bytes ->
             Agent.update(stage, &Map.update!(&1, kind, fn old -> [bytes | old] end))
           end}
        end)

      adapter = %{
        metadata_sink: adapter.metadata,
        rootfs_sink: adapter.rootfs,
        metadata_source: fn -> Agent.get(stage, &Enum.reverse(&1.metadata)) end,
        rootfs_source: fn -> Agent.get(stage, &Enum.reverse(&1.rootfs)) end
      }

      assert {:ok, accepted} =
               Images.copy(target, source, %{"fingerprint" => fingerprint},
                 mode: "relay",
                 relay: adapter
               )

      assert accepted.operation == "/1.0/operations/split-relay"
      [request] = Enum.filter(HTTPFixture.requests(target_fixture), &(&1.method == "POST"))
      {_, actual_metadata, _, actual_rootfs} = multipart(request)
      assert actual_metadata == metadata
      assert actual_rootfs == rootfs
    end
  end

  defp split_export(metadata, rootfs) do
    boundary = "fixture-split-relay"

    header = fn kind ->
      [{"content-disposition", "form-data; name=\"#{kind}\"; filename=\"#{kind}.tar\""}]
    end

    body =
      IO.iodata_to_binary([
        :cow_multipart.first_part(boundary, header.("metadata")),
        metadata,
        :cow_multipart.part(boundary, header.("rootfs")),
        rootfs,
        :cow_multipart.close(boundary)
      ])

    raw =
      "HTTP/1.1 200 OK\r\nContent-Type: multipart/form-data; boundary=#{boundary}\r\nContent-Length: #{byte_size(body)}\r\n\r\n" <>
        body

    {raw, Base.encode16(:crypto.hash(:sha256, metadata <> rootfs), case: :lower)}
  end

  defp tls_backend(identity, handler) do
    start_supervised!(
      {HTTPFixture,
       transport: :ssl,
       certfile: identity.certfile,
       keyfile: identity.keyfile,
       handler: fn request ->
         if URI.parse(request.target).path == "/1.0" do
           %{
             status: 200,
             body: %{
               type: "sync",
               metadata: %{
                 api_version: "1.0",
                 api_extensions: ["images_push_relay", "image_copy_profile"],
                 environment: %{certificate: File.read!(identity.certfile)}
               }
             }
           }
         else
           handler.(request)
         end
       end},
      id: make_ref()
    )
  end

  defp tls_client(fixture, identity, context) do
    connection =
      Connection.https!(HTTPFixture.endpoint(fixture).url,
        owner: :fixture,
        tls: [cacertfile: identity.cafile, certfile: identity.certfile, keyfile: identity.keyfile]
      )

    {:ok, client} = Incus.connect(connection, context)
    client
  end

  test "alias type/architecture helpers and native temporary secrets match the official client",
       %{root: root, context: context} do
    fixture =
      backend(root, fn request ->
        path = URI.parse(request.target).path

        cond do
          String.contains?(path, "/aliases/") ->
            %{
              status: 200,
              body: %{type: "sync", metadata: %{name: "native", type: "", target: "fingerprint"}}
            }

          String.ends_with?(path, "/secret") ->
            %{
              status: 202,
              body: %{
                type: "async",
                operation: "/1.0/operations/secret-id",
                metadata: %{id: "secret-id", metadata: %{secret: "fixture-secret"}}
              }
            }

          true ->
            %{
              status: 200,
              body: %{
                type: "sync",
                metadata: %{fingerprint: "fingerprint", architecture: "aarch64"}
              }
            }
        end
      end)

    client = client(fixture, context)

    for {method, arguments, values} <- [
          {"GetImageAliasType", %{"image_type" => "container", "name" => "native"},
           ["container", "native"]},
          {"GetImageAliasArchitectures", %{"image_type" => "container", "name" => "native"},
           ["container", "native"]},
          {"GetImageSecret", %{"fingerprint" => "fingerprint"}, ["fingerprint"]}
        ] do
      result =
        driver(root, %{socket: HTTPFixture.endpoint(fixture).socket, action: method, args: values})

      refute result["error"]
      assert {:ok, response} = Incus.call(client, method, arguments)

      case method do
        "GetImageAliasType" ->
          assert response.metadata.data["type"] == hd(result["outputs"])["type"]

        "GetImageAliasArchitectures" ->
          assert response.metadata["aarch64"].data["target"] ==
                   hd(result["outputs"])["aarch64"]["target"]

        "GetImageSecret" ->
          assert response.metadata == hd(result["outputs"])
          assert response.operation == "/1.0/operations/secret-id"
      end
    end
  end

  defp driver(root, input) do
    file = Path.join(root, "input.json")
    File.write!(file, Jason.encode!(input))
    File.chmod!(file, 0o600)
    {out, status} = System.cmd(@driver, [file], stderr_to_stdout: true)
    assert status == 0, out
    Jason.decode!(out)
  end

  defp client(fixture, context) do
    {:ok, client} =
      Incus.connect(
        Connection.unix!(HTTPFixture.endpoint(fixture).socket, owner: :fixture),
        context
      )

    client
  end

  defp backend(root, handler),
    do:
      start_supervised!(
        {HTTPFixture,
         transport: :gen_tcp,
         path: Path.join(root, "s-#{System.unique_integer([:positive])}"),
         handler: fn request ->
           if URI.parse(request.target).path == "/1.0",
             do: %{
               status: 200,
               body: %{
                 type: "sync",
                 metadata: %{
                   api_version: "1.0",
                   api_extensions: ["image_compression_algorithm"],
                   environment: %{}
                 }
               }
             },
             else: handler.(request)
         end},
        id: make_ref()
      )

  defp multipart(request) do
    {_, _, params} = :cow_http_hd.parse_content_type(request.headers["content-type"])
    {_, boundary} = List.keyfind(params, "boundary", 0)
    {:ok, headers, rest} = :cow_multipart.parse_headers(request.body, boundary)
    {:done, metadata, rest} = :cow_multipart.parse_body(rest, boundary)
    {:ok, root_headers, rest} = :cow_multipart.parse_headers(rest, boundary)
    {:done, rootfs, _} = :cow_multipart.parse_body(rest, boundary)
    {headers, metadata, root_headers, rootfs}
  end
end
