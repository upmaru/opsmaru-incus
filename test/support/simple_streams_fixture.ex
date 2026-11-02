defmodule Opsmaru.TestSupport.SimpleStreamsFixture do
  @moduledoc false
  # A private SimpleStreams server with one split image, its refreshed client and
  # the image as the pinned client lists it. Only the tests ever contact it.
  alias Opsmaru.Incus.{Connection, Context, Model, SimpleStreams}
  alias Opsmaru.TestSupport.{HTTPFixture, TLSIdentity}

  @metadata "simplestreams-metadata"
  @rootfs :binary.copy(<<1, 2, 3, 250>>, 2_048)

  def start(root, pinned) do
    identity =
      TLSIdentity.generate(root, "s12-#{System.unique_integer([:positive])}", "localhost")

    routes = routes()

    fixture =
      ExUnit.Callbacks.start_supervised!(
        {HTTPFixture,
         transport: :ssl,
         certfile: identity.certfile,
         keyfile: identity.keyfile,
         handler: fn request ->
           body = Map.get(routes, request.target)
           status = if body, do: "200 OK", else: "404 Not Found"
           body = body || ""

           %{
             raw:
               "HTTP/1.1 #{status}\r\nContent-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n" <>
                 body
           }
         end},
        id: make_ref()
      )

    url = HTTPFixture.endpoint(fixture).url
    tls = [cacertfile: identity.cafile, certfile: identity.certfile, keyfile: identity.keyfile]
    connection = Connection.https!(url, owner: :fixture, timeout: 5_000, tls: tls)
    context = Context.new!(owner: :fixture, identity: :verified, ready?: fn -> true end)
    certificate = if pinned, do: File.read!(identity.certfile), else: ""

    client =
      SimpleStreams.new!(connection, context, architecture: "x86_64", certificate: certificate)

    {:ok, client} = SimpleStreams.refresh(client)
    {:ok, image} = SimpleStreams.image(client, fingerprint())

    %{
      fixture: fixture,
      origin: url,
      client: client,
      certificate: certificate,
      ca: File.read!(identity.cafile),
      image: Model.encode(image),
      metadata: @metadata,
      rootfs: @rootfs
    }
  end

  def fingerprint, do: hash(@metadata <> @rootfs)

  # Image file requests after the catalog was loaded.
  def downloads(server),
    do:
      HTTPFixture.requests(server.fixture)
      |> Enum.map(& &1.target)
      |> Enum.filter(&String.starts_with?(&1, "/images/"))

  defp routes do
    item = fn type, path, bytes ->
      %{"ftype" => type, "path" => path, "sha256" => hash(bytes), "size" => byte_size(bytes)}
    end

    meta =
      item.("incus.tar.xz", "images/fixture/incus.tar.xz", @metadata)
      |> Map.put("combined_squashfs_sha256", fingerprint())

    product = %{
      "arch" => "amd64",
      "aliases" => "fixture/edge",
      "os" => "Fixture",
      "release" => "edge",
      "versions" => %{
        "20261101" => %{
          "items" => %{
            "incus.tar.xz" => meta,
            "root.squashfs" => item.("squashfs", "images/fixture/root.squashfs", @rootfs)
          }
        }
      }
    }

    index = %{
      "format" => "index:1.0",
      "index" => %{
        "images" => %{
          "datatype" => "image-downloads",
          "path" => "streams/v1/images.json",
          "products" => ["fixture:edge:amd64"]
        }
      }
    }

    %{
      "/streams/v1/index.json" => Jason.encode!(index),
      "/streams/v1/images.json" =>
        Jason.encode!(%{
          "format" => "products:1.0",
          "products" => %{"fixture:edge:amd64" => product}
        }),
      "/images/fixture/incus.tar.xz" => @metadata,
      "/images/fixture/root.squashfs" => @rootfs
    }
  end

  defp hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
