defmodule Opsmaru.Incus.SimpleStreamsReferenceTest do
  @moduledoc "S12 SimpleStreams catalog errors, image files, cache and deltas compared with the pinned client."
  use ExUnit.Case, async: true
  alias Opsmaru.Incus.{Connection, Context, Error, SimpleStreams}
  alias Opsmaru.TestSupport.{HTTPFixture, TLSIdentity}

  @driver Path.expand("../.integration/simplestreams-file-driver", __DIR__)
  @info_driver Path.expand("../.integration/simplestreams-origin-info-driver", __DIR__)
  @index "/streams/v1/index.json"
  @products "/streams/v1/images.json"
  # The pinned ConnectSimpleStreams default expiry and a reading past it.
  @fresh 3_600_000_000_000
  @expired 1

  # The pinned cache directory layout: <cache>/<sha256 of the URL>/<file name>.
  # A missing namespace makes writes fail, which the pinned client ignores.
  defmodule DirCache do
    @behaviour Opsmaru.Incus.SimpleStreams.CacheAdapter

    def read(config, namespace, name) do
      case File.read(Path.join([config.root, namespace, name])) do
        {:ok, body} -> {:ok, body, config.age}
        _ -> :miss
      end
    end

    def write(config, namespace, name, body),
      do: File.write(Path.join([config.root, namespace, name]), body)

    def invalidate(config, namespace) do
      File.rm_rf!(Path.join(config.root, namespace))
      :ok
    end
  end

  # Applies a delta as the fixture xdelta3 does: the source followed by the delta.
  defmodule FileDelta do
    @behaviour Opsmaru.Incus.SimpleStreams.DeltaAdapter

    def convert(_config, request, emit) do
      {:ok, buffer} = Agent.start_link(fn -> [] end)

      {:ok, _} =
        request.download_delta.(fn bytes ->
          Agent.update(buffer, &[bytes | &1])
          :ok
        end)

      delta = Agent.get(buffer, &(&1 |> Enum.reverse() |> IO.iodata_to_binary()))
      emit.(File.read!(request.base.source) <> delta)
    end

    def cleanup(_config, _id, _outcome), do: :ok
  end

  setup_all do
    File.mkdir_p!(Path.dirname(@driver))

    for {output, package} <- [{@driver, "./simplestreamsfile"}, {@info_driver, "./origininfo"}] do
      {out, status} =
        System.cmd("mise", ["exec", "--", "go", "build", "-o", output, package],
          cd: Path.expand("reference", __DIR__),
          env: [{"GOTOOLCHAIN", "local"}],
          stderr_to_stdout: true
        )

      assert status == 0, out
    end

    :ok
  end

  setup do
    root = Path.join(System.tmp_dir!(), "op-ssr-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    identity = TLSIdentity.generate(root, "ssr", "localhost")
    {:ok, routes} = Agent.start_link(fn -> %{} end)
    fixture = fixture(identity, routes)
    url = HTTPFixture.endpoint(fixture).url
    %{root: root, identity: identity, routes: routes, fixture: fixture, url: url}
  end

  test "S12 origin metadata reports the explicit certificate as the pinned GetConnectionInfo",
       %{root: root, identity: identity, url: url, fixture: fixture} do
    certificate = File.read!(identity.certfile)

    for pinned <- ["", certificate] do
      path = Path.join(root, "info-#{System.unique_integer([:positive])}.json")

      File.write!(
        path,
        Jason.encode!(%{URL: url <> "/", Certificate: pinned, Protocol: "simplestreams"})
      )

      {out, status} =
        System.cmd("sh", ["-c", "exec \"$1\" < \"$2\"", "oracle", @info_driver, path],
          stderr_to_stdout: true
        )

      assert status == 0, out
      expected = Jason.decode!(out)

      assert {:ok, info} =
               SimpleStreams.connection_info(client(identity, url, certificate: pinned))

      assert info.certificate == expected["Certificate"] and info.url == expected["URL"]
      assert info.addresses == expected["Addresses"] and info.protocol == expected["Protocol"]
    end

    for bad <- ["not a certificate", certificate <> certificate, 1] do
      assert_raise ArgumentError, fn -> client(identity, url, certificate: bad) end
    end

    assert HTTPFixture.requests(fixture) == []
  end

  test "S12 catalog failures carry the pinned error text and wrapping",
       %{root: root, identity: identity, routes: routes, url: url} do
    {split, _} = image("meta", "root")

    cases = [
      {:index_404, %{@index => {404, "missing"}}},
      {:index_500, %{@index => {500, "broken"}}},
      {:index_empty, %{@index => {200, ""}}},
      {:index_corrupt, %{@index => {200, "not \"json\"\n"}}},
      {:products_404, Map.put(stream([split]), @products, {404, ""})},
      {:products_empty, Map.put(stream([split]), @products, {200, ""})},
      {:products_corrupt, Map.put(stream([split]), @products, {200, "{]"})},
      {:no_index, %{@index => {200, Jason.encode!(%{"format" => "index:1.0"})}}}
    ]

    for {label, route} <- cases do
      Agent.update(routes, fn _ -> route end)
      native = oracle(root, identity, url, %{Action: "images"})

      case {native, SimpleStreams.refresh(client(identity, url))} do
        {%{"fingerprints" => expected}, {:ok, next}} ->
          assert {:ok, expected} == SimpleStreams.fingerprints(next), inspect(label)

        {%{"error" => expected}, {:error, %Error{kind: :native, message: message}}} ->
          if label in [:index_corrupt, :products_corrupt] do
            # Only the decoder's own detail differs from encoding/json (approved difference).
            [prefix | _] = String.split(expected, "JSON from ")
            [path | _] = String.split(String.trim_leading(expected, prefix <> "JSON from "), ": ")
            assert String.starts_with?(message, prefix <> "JSON from " <> path <> ": "), message

            if label == :index_corrupt,
              do: assert(String.ends_with?(message, ~S| ("not \"json\"\n")|)),
              else: refute(message =~ "{]")
          else
            assert message == expected, inspect(label)
          end

        other ->
          flunk("#{label}: #{inspect(other)}")
      end
    end
  end

  test "S12 image files agree with the pinned GetImageFile, including its combined fingerprint",
       %{root: root, identity: identity, routes: routes, url: url} do
    {split, split_routes} = image("meta-bytes", :binary.copy(<<0, 255, 7>>, 3_000))
    {unified, unified_routes} = image("unified-bytes", nil, "20261102")

    Agent.update(routes, fn _ ->
      Map.merge(stream([split, unified]), Map.merge(split_routes, unified_routes))
    end)

    cases = [
      {split.fingerprint, true, true},
      {split.fingerprint, false, true},
      {split.fingerprint, true, false},
      {unified.fingerprint, true, true},
      {unified.fingerprint, true, false},
      {String.slice(unified.fingerprint, 0, 12), true, true},
      {"missing", true, true},
      {"", true, true},
      {split.fingerprint, false, false}
    ]

    for {fingerprint, meta, rootfs} <- cases do
      label = inspect({fingerprint, meta, rootfs})

      native =
        oracle(root, identity, url, %{
          Action: "file",
          Fingerprint: fingerprint,
          Meta: meta,
          Rootfs: rootfs
        })

      compare_file(native, image_file(identity, url, fingerprint, meta, rootfs), label)
    end

    # Hash mismatches and failed downloads report the HTTPS URL, as natively.
    for {path, reply} <- [
          {"/images/meta-bytes", {200, "corrupt"}},
          {"/images/root-meta-bytes", {404, ""}},
          {"/images/root-meta-bytes", {500, ""}}
        ] do
      Agent.update(routes, &Map.put(&1, path, reply))

      native =
        oracle(root, identity, url, %{
          Action: "file",
          Fingerprint: split.fingerprint,
          Meta: true,
          Rootfs: true
        })

      assert native["error"], inspect(native)
      compare_file(native, image_file(identity, url, split.fingerprint, true, true), path)
      Agent.update(routes, &Map.merge(&1, split_routes))
    end
  end

  test "S12 deltas use the host source like the pinned DeltaSourceRetriever",
       %{root: root, identity: identity, routes: routes, fixture: fixture, url: url} do
    base = "base-rootfs|"
    delta = "delta-bytes"
    {older, older_routes} = image("old-meta", base, "20261001")

    {current, current_routes} =
      image("new-meta", base <> delta, "20261101", delta: {older, delta})

    Agent.update(routes, fn _ ->
      stream([older, current]) |> Map.merge(older_routes) |> Map.merge(current_routes)
    end)

    source = Path.join(root, "base.squashfs")
    File.write!(source, base)
    bin = Path.join(root, "bin")
    File.mkdir_p!(bin)
    xdelta = Path.join(bin, "xdelta3")
    # Called as xdelta3 -f -d -s SOURCE DELTA OUTPUT.
    File.write!(xdelta, "#!/bin/sh\ncat \"$4\" \"$5\" > \"$6\"\n")
    File.chmod!(xdelta, 0o700)

    for sources <- [
          %{older.fingerprint => source},
          %{older.fingerprint => ""},
          %{"other" => source}
        ] do
      label = inspect(sources)
      before = length(HTTPFixture.requests(fixture))

      native =
        oracle(
          root,
          identity,
          url,
          %{
            Action: "file",
            Fingerprint: current.fingerprint,
            Meta: true,
            Rootfs: true,
            Delta: sources
          },
          bin
        )

      go = paths(fixture, before)

      retriever = fn fingerprint ->
        if (sources[fingerprint] || "") == "", do: nil, else: sources[fingerprint]
      end

      client = client(identity, url, delta_adapter: FileDelta, delta_config: nil)
      {:ok, client} = SimpleStreams.refresh(client)
      before = length(HTTPFixture.requests(fixture))

      result =
        SimpleStreams.image_file(client, current.fingerprint, sinks(true, true),
          delta_source: retriever
        )

      compare_file(native, collect(result), label)
      assert paths(fixture, before) == downloads(go), label
      assert downloads(go) != [], label
    end
  end

  test "S12 the host cache follows the pinned cache directory's expiry, fallback and invalidation",
       %{root: root, identity: identity, routes: routes, fixture: fixture, url: url} do
    {split, split_routes} = image("meta", "root")
    {newer, newer_routes} = image("meta-2", "root-2", "20261103")
    ok = stream([split]) |> Map.merge(split_routes)
    namespace = :crypto.hash(:sha256, url) |> Base.encode16(case: :lower)
    go = Path.join(root, "go-cache")
    ours = Path.join(root, "our-cache")

    # {step, reply routes, whether the cache has expired, action}
    steps = [
      {:fills, ok, false, "images"},
      {:fresh_skips_request, %{@index => {500, ""}}, false, "images"},
      {:stale_fallback_on_error, %{@index => {500, ""}}, true, "images"},
      {:stale_refetch,
       stream([split, newer]) |> Map.merge(split_routes) |> Map.merge(newer_routes), true,
       "images"},
      {:empty_body_never_falls_back, Map.put(ok, @index, {200, ""}), true, "images"},
      {:missing_file_invalidates, Map.put(ok, "/images/root-meta", {404, ""}), true, "file"},
      {:refills, ok, true, "images"},
      # The status alone invalidates; a body past max_response_bytes is never read.
      {:oversized_missing_file_invalidates,
       Map.put(ok, "/images/root-meta", {404, :binary.copy("x", 9 * 1_048_576)}), true, "file"},
      {:refills_again, ok, true, "images"}
    ]

    for {label, route, expired, action} <- steps do
      Agent.update(routes, fn _ -> route end)
      # Like ConnectSimpleStreams, each connection creates its namespace directory.
      for dir <- [go, ours], do: File.mkdir_p!(Path.join(dir, namespace))
      before = length(HTTPFixture.requests(fixture))

      input = %{
        Action: action,
        CachePath: go,
        CacheExpiry: if(expired, do: @expired, else: @fresh)
      }

      input =
        if action == "file",
          do: Map.merge(input, %{Fingerprint: split.fingerprint, Meta: true, Rootfs: true}),
          else: input

      native = oracle(root, identity, url, input)
      native_paths = paths(fixture, before)
      before = length(HTTPFixture.requests(fixture))
      age = if expired, do: 7_200_000, else: 0

      client =
        client(identity, url, cache_adapter: DirCache, cache_config: %{root: ours, age: age})

      result =
        with {:ok, client} <- SimpleStreams.refresh(client) do
          if action == "images",
            do: SimpleStreams.fingerprints(client),
            else: collect(SimpleStreams.image_file(client, split.fingerprint, sinks(true, true)))
        end

      case {native, result} do
        {%{"fingerprints" => expected}, {:ok, actual}} ->
          assert actual == expected, inspect(label)

        {%{"error" => expected}, {:error, %Error{message: message}}} ->
          assert message == expected, inspect(label)

        {%{"response" => _}, _} ->
          compare_file(native, result, inspect(label))

        other ->
          flunk("#{label}: #{inspect(other)}")
      end

      assert paths(fixture, before) == native_paths, inspect(label)
      assert tree(Path.join(ours, namespace)) == tree(Path.join(go, namespace)), inspect(label)
    end
  end

  defmodule BrokenCache do
    def read(:raise, _, _), do: raise("broken cache")
    def read(:garbage, _, _), do: {:ok, :not_a_body, -1}
    def write(_, _, _, _), do: raise("broken cache")
    def invalidate(_, _), do: throw(:broken)
  end

  test "S12 cache options are explicit and cache failures are ignored as natively",
       %{identity: identity, routes: routes, fixture: fixture, url: url} do
    {split, split_routes} = image("meta", "root")
    Agent.update(routes, fn _ -> stream([split]) |> Map.merge(split_routes) end)

    for config <- [:raise, :garbage] do
      client = client(identity, url, cache_adapter: BrokenCache, cache_config: config)
      assert {:ok, next} = SimpleStreams.refresh(client)
      assert {:ok, [split.fingerprint]} == SimpleStreams.fingerprints(next)
      refute inspect(next) =~ "broken"
    end

    # A 404 invalidation that throws still reports the native download error.
    Agent.update(routes, &Map.put(&1, "/images/root-meta", {404, ""}))
    client = client(identity, url, cache_adapter: BrokenCache, cache_config: :raise)
    {:ok, client} = SimpleStreams.refresh(client)

    assert {:error, %Error{message: "Unable to fetch " <> _}} =
             SimpleStreams.image_file(client, split.fingerprint, sinks(true, true))

    for bad <- [
          [cache_adapter: DirCache],
          [cache_config: %{}],
          [cache_adapter: String, cache_config: %{}],
          [cache_adapter: DirCache, cache_config: %{}, cache_expiry: 0],
          [cache_expiry: 1_000]
        ] do
      assert_raise ArgumentError, fn -> client(identity, url, bad) end
    end

    # Three refreshes of two catalog files, then the metadata and the missing rootfs.
    assert length(HTTPFixture.requests(fixture)) == 8
  end

  defp compare_file(%{"error" => expected}, result, label) do
    assert {:error, %Error{message: ^expected}} = result, label
  end

  defp compare_file(%{"response" => response} = native, result, label) do
    assert {:ok, parts, bytes} = result, label

    assert %{
             "MetaName" => if(parts[:metadata], do: parts.metadata.name, else: ""),
             "MetaSize" => if(parts[:metadata], do: parts.metadata.size, else: 0),
             "RootfsName" => if(parts[:rootfs], do: parts.rootfs.name, else: ""),
             "RootfsSize" => if(parts[:rootfs], do: parts.rootfs.size, else: 0)
           } == response,
           label

    assert Base.encode64(bytes.metadata) == native["meta"] and
             Base.encode64(bytes.rootfs) == native["rootfs"],
           label
  end

  defp image_file(identity, url, fingerprint, meta, rootfs) do
    with {:ok, client} <- SimpleStreams.refresh(client(identity, url)),
         do: collect(SimpleStreams.image_file(client, fingerprint, sinks(meta, rootfs)))
  end

  defp sinks(meta, rootfs) do
    owner = self()
    sink = fn part -> fn bytes -> send(owner, {part, bytes}) && :ok end end

    for {part, wanted} <- [metadata: meta, rootfs: rootfs],
        wanted,
        into: %{},
        do: {part, sink.(part)}
  end

  defp collect({:ok, parts}),
    do: {:ok, parts, %{metadata: drain(:metadata), rootfs: drain(:rootfs)}}

  defp collect(error) do
    _ = {drain(:metadata), drain(:rootfs)}
    error
  end

  defp drain(part, acc \\ []) do
    receive do
      {^part, bytes} -> drain(part, [bytes | acc])
    after
      0 -> acc |> Enum.reverse() |> IO.iodata_to_binary()
    end
  end

  # Products with the pinned delta layout: a vcdiff item naming its base version.
  defp image(meta, root, serial \\ "20261101", opts \\ []) do
    items =
      if root do
        %{
          "meta" =>
            item("incus.tar.xz", "images/#{meta}", meta, %{
              "combined_squashfs_sha256" => hash(meta <> root)
            }),
          "root" => item("squashfs", "images/root-#{meta}", root)
        }
      else
        %{"meta" => item("incus_combined.tar.gz", "images/#{meta}", meta)}
      end

    {items, routes} =
      case opts[:delta] do
        {base, bytes} ->
          delta =
            Map.put(
              item("squashfs.vcdiff", "images/delta-#{meta}", bytes),
              "delta_base",
              base.serial
            )

          {Map.put(items, "delta", delta), %{"/images/delta-#{meta}" => {200, bytes}}}

        nil ->
          {items, %{}}
      end

    routes = Map.put(routes, "/images/#{meta}", {200, meta})
    routes = if root, do: Map.put(routes, "/images/root-#{meta}", {200, root}), else: routes
    fingerprint = if root, do: hash(meta <> root), else: hash(meta)
    {%{fingerprint: fingerprint, serial: serial, items: items}, routes}
  end

  defp item(type, path, bytes, extra \\ %{}),
    do:
      Map.merge(
        %{"ftype" => type, "path" => path, "sha256" => hash(bytes), "size" => byte_size(bytes)},
        extra
      )

  defp stream(images) do
    versions = Map.new(images, &{&1.serial, %{"items" => &1.items}})

    product = %{
      "arch" => "amd64",
      "aliases" => "fixture",
      "os" => "Fixture",
      "release" => "one",
      "versions" => versions
    }

    index = %{
      "format" => "index:1.0",
      "index" => %{
        "images" => %{
          "datatype" => "image-downloads",
          "path" => "streams/v1/images.json",
          "products" => ["fixture:amd64"]
        }
      }
    }

    %{
      @index => {200, Jason.encode!(index)},
      @products =>
        {200,
         Jason.encode!(%{"format" => "products:1.0", "products" => %{"fixture:amd64" => product}})}
    }
  end

  defp fixture(identity, routes) do
    start_supervised!(
      {HTTPFixture,
       transport: :ssl,
       certfile: identity.certfile,
       keyfile: identity.keyfile,
       handler: fn request ->
         {status, body} = Agent.get(routes, &Map.get(&1, request.target, {404, ""}))

         %{
           raw:
             "HTTP/1.1 #{SimpleStreams.status_line(status)}\r\nContent-Length: #{byte_size(body)}\r\n" <>
               "Connection: close\r\n\r\n" <> body
         }
       end},
      id: make_ref()
    )
  end

  defp client(identity, url, opts \\ []) do
    connection =
      Connection.https!(url,
        owner: :fixture,
        tls: [cacertfile: identity.cafile, certfile: identity.certfile, keyfile: identity.keyfile]
      )

    context = Context.new!(owner: :fixture, identity: :verified, ready?: fn -> true end)
    SimpleStreams.new!(connection, context, Keyword.merge([architecture: "x86_64"], opts))
  end

  defp oracle(root, identity, url, input, bin \\ nil) do
    path = Path.join(root, "oracle-#{System.unique_integer([:positive])}.json")
    input = Map.merge(%{URL: url, Certificate: File.read!(identity.certfile), Temp: root}, input)
    File.write!(path, Jason.encode!(input))
    env = if bin, do: [{"PATH", bin <> ":" <> System.get_env("PATH")}], else: []

    {out, status} =
      System.cmd("sh", ["-c", "exec \"$1\" < \"$2\"", "oracle", @driver, path],
        env: env,
        stderr_to_stdout: true
      )

    assert status == 0, out
    Jason.decode!(out)
  end

  defp paths(fixture, before),
    do: HTTPFixture.requests(fixture) |> Enum.drop(before) |> Enum.map(& &1.target)

  # Image file requests only: the pinned client loads its catalog lazily inside
  # GetImageFile, ours in an explicit refresh before it.
  defp downloads(paths), do: Enum.reject(paths, &(&1 in [@index, @products]))

  defp tree(dir) do
    case File.ls(dir) do
      {:ok, names} -> Map.new(names, &{&1, File.read!(Path.join(dir, &1))})
      _ -> :absent
    end
  end

  defp hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
