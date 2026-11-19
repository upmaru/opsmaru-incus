defmodule Opsmaru.Incus.GatewayImageCopyTest do
  use Opsmaru.TestSupport.GatewayCase, async: true
  alias Opsmaru.TestSupport.NativeImageBackend, as: Backend
  alias Opsmaru.TestSupport.NativeMigrationBackend

  @project "image-project"

  defmodule Host do
    @behaviour Opsmaru.Incus.Gateway.Host
    def ready?(_), do: true

    def authorize(request, config) do
      if request.peer.certificate == config.client.der and
           request.project in [nil, "image-project"],
         do: {:ok, :caller},
         else: {:error, :unauthenticated}
    end

    def identity(_, config), do: {:ok, config.identity}
    def valid?(_, grant, _), do: grant in [:caller, :pending_image]

    def admit_image_secret(request, config) do
      send(config.observer, {:image_admission, config.name, request})

      # The trusted backend does not check image secrets, so the host verifies
      # the secret against its pending transfer (here a fixed expectation per
      # route), with the fingerprint, project and a loopback server peer.
      expected = Map.fetch!(config.secrets, request.image.route)

      if config.admit_images and Plug.Crypto.secure_compare(request.image.secret, expected) and
           request.image.fingerprint in [nil, config.fingerprint] and
           request.project == "image-project" and request.target == nil and
           request.peer.address == {127, 0, 0, 1} do
        {:ok, :pending_image}
      else
        {:error, :forbidden}
      end
    end
  end

  setup_all do
    NativeMigrationBackend.build!()
    :ok
  end

  for mode <- [:relay, :pull, :push] do
    test "pinned image #{mode} copy crosses source and target gateways with public endpoint identity",
         context do
      source = Backend.start(context, "source")
      target = Backend.start(context, "target")
      source_endpoint = mounted(context, source)
      target_endpoint = mounted(context, target)

      result = copy(context, unquote(mode), source_endpoint, target_endpoint)

      assert result["completed"], inspect(Map.take(result, ["error", "accepted"]))

      for {key, endpoint} <- [{"source_info", source_endpoint}, {"target_info", target_endpoint}] do
        assert result[key]["URL"] == endpoint[:URL]
        assert result[key]["Certificate"] == endpoint[:Certificate]

        assert result[key]["Addresses"] == [
                 endpoint[:URL],
                 "https://gateway.example.com:#{URI.parse(endpoint[:URL]).port}"
               ]

        refute inspect(result[key]) =~ "10.0.2.15"
        refute inspect(result[key]) =~ "127.0.0.1:9"
      end

      verify(unquote(mode), source, target, source_endpoint, target_endpoint)
    end
  end

  for mode <- [:pull, :push] do
    test "image #{mode} without host image admission is refused before the peer reaches the backend",
         context do
      source = Backend.start(context, "source")
      target = Backend.start(context, "target")
      source_endpoint = mounted(context, source, admit_images: false)
      target_endpoint = mounted(context, target, admit_images: false)

      result = copy(context, unquote(mode), source_endpoint, target_endpoint)

      refute result["completed"]
      assert result["error"] =~ "not authorized"

      case unquote(mode) do
        :pull ->
          assert_received {:image_admission, "source", %{image: %{route: :info}}}
          refute Enum.any?(Backend.events(source), &match?({:exported, _, _}, &1))
          refute Enum.any?(Backend.requests(source), &String.contains?(&1.target, "secret="))

        :push ->
          assert_received {:image_admission, "target", %{image: %{route: :upload}}}
          refute Enum.any?(Backend.events(target), &match?({:uploaded, _, _, _}, &1))
      end
    end
  end

  for mode <- [:pull, :push] do
    test "image #{mode} with a secret the host does not hold pending is refused although the trusted backend would accept it",
         context do
      stale = Map.new(~w(info export upload wait)a, &{&1, "stale-secret"})
      source = Backend.start(context, "source")
      target = Backend.start(context, "target")
      source_endpoint = mounted(context, source, secrets: stale)
      target_endpoint = mounted(context, target, secrets: stale)

      result = copy(context, unquote(mode), source_endpoint, target_endpoint)

      refute result["completed"]
      assert result["error"] =~ "not authorized"

      case unquote(mode) do
        :pull ->
          assert_received {:image_admission, "source", %{image: %{route: :info} = image}}
          assert image.secret == "pull-secret"
          refute Enum.any?(Backend.requests(source), &String.contains?(&1.target, "secret="))

        :push ->
          assert_received {:image_admission, "target", %{image: %{route: :upload} = image}}
          assert image.secret == "push-secret"
          refute Enum.any?(Backend.events(target), &match?({:uploaded, _, _, _}, &1))
      end
    end
  end

  defp copy(context, mode, source_endpoint, target_endpoint) do
    NativeMigrationBackend.run(context.root, %{
      Action: "image",
      Mode: mode,
      Body: Backend.model(),
      Source: source_endpoint,
      Target: target_endpoint
    })
  end

  defp verify(:relay, source, target, _source_endpoint, _target_endpoint) do
    # The caller carries the bytes over its own authenticated connections; no
    # server peer is admitted and no secret is created.
    assert [{:exported, "source", nil}] = filter(source, :exported)
    assert [{:uploaded, "target", :caller, content}] = filter(target, :uploaded)
    assert content == Backend.content()
    refute_received {:image_admission, _, _}
  end

  defp verify(:pull, source, target, source_endpoint, _target_endpoint) do
    fingerprint = Backend.fingerprint()
    assert [{:secret_created, "source"}] = filter(source, :secret_created)
    assert [{:exported, "source", "pull-secret"}] = filter(source, :exported)

    # The target server dials the source gateway's public URL, never a guest
    # address, and is admitted only to the image info and export routes.
    assert [{:outbound, "target", :pull, server, result}] = filter(target, :outbound)
    assert server == source_endpoint[:URL]
    assert result["fingerprint"] == fingerprint

    assert_received {:image_admission, "source", %{image: %{route: :info} = info} = request}
    assert info.fingerprint == fingerprint
    assert request.peer.certificate == nil
    assert request.project == @project
    assert_received {:image_admission, "source", %{image: %{route: :export}}}
    refute_received {:image_admission, _, _}
  end

  defp verify(:push, source, target, _source_endpoint, target_endpoint) do
    fingerprint = Backend.fingerprint()
    assert [{:push_token, "target", _}] = filter(target, :push_token)
    assert [{:export_request, "source", export}] = filter(source, :export_request)
    assert export["target"] == target_endpoint[:URL]
    assert export["certificate"] == target_endpoint[:Certificate]
    assert export["secret"] == "push-secret"

    # The source server dials the target gateway's public URL and is admitted
    # only to the upload and its operation wait.
    assert [{:outbound, "source", :push, server, %{"pushed" => true}}] = filter(source, :outbound)
    assert server == target_endpoint[:URL]
    assert [{:uploaded, "target", {:peer, "push-secret"}, content}] = filter(target, :uploaded)
    assert content == Backend.content()

    assert_received {:image_admission, "target", %{image: %{route: :upload} = upload} = request}
    assert upload.fingerprint == fingerprint
    assert request.peer.certificate == nil

    assert_received {:image_admission, "target",
                     %{image: %{route: :wait, secret: "push-secret"}, operation: "pushed"}}

    refute_received {:image_admission, _, _}
  end

  defp filter(side, tag), do: Enum.filter(Backend.events(side), &(elem(&1, 0) == tag))

  defp mounted(context, side, opts \\ []) do
    server = TLSIdentity.generate(context.root, "front-#{side.name}", "localhost")
    client = TLSIdentity.generate(context.root, "client-#{side.name}", "caller")
    {ref, port} = GatewayServer.start_https(server, client.cafile)
    on_exit(fn -> GatewayServer.stop(ref) end)

    gateway =
      Gateway.new!(
        connection: side.connection,
        host: Host,
        admission: context.admission,
        host_config: %{
          observer: self(),
          name: side.name,
          client: client,
          fingerprint: Backend.fingerprint(),
          admit_images: Keyword.get(opts, :admit_images, true),
          secrets:
            Keyword.get(opts, :secrets, %{
              info: "pull-secret",
              export: "pull-secret",
              upload: "push-secret",
              wait: "push-secret"
            }),
          identity: %{
            origin: "https://gateway.example.com:#{port}",
            addresses: ["gateway.example.com:#{port}"],
            certificate: File.read!(server.certfile),
            connection: side.connection,
            api_extensions: Backend.extensions()
          }
        }
      )

    GatewayServer.put_gateway(gateway, port)

    %{
      URL: "https://localhost:#{port}",
      Certificate: File.read!(server.certfile),
      ClientCertificate: File.read!(client.certfile),
      ClientKey: File.read!(client.keyfile),
      Project: @project
    }
  end
end
