# Verifies a built release cassette the way a host uses it: the .sha256 file
# matches the cassette, and the cassette imports into a fresh index, pinned to
# that SHA-256, as the opsmaru_incus cassette with both sources searchable and
# exactly the operations of the two documents.
#
# Usage: mix run --no-start scripts/verify-cassette.exs CASSETTE SHA256_FILE VERSION
alias Opsmaru.Incus.Operations.{Composite, Native}

[path, sha_path, version] = System.argv()

fail = fn message ->
  IO.puts(:stderr, "cassette verification failed: #{message}")
  System.halt(1)
end

sha256 = :sha256 |> :crypto.hash(File.read!(path)) |> Base.encode16(case: :lower)

case sha_path |> File.read!() |> String.split() do
  [^sha256, name] ->
    if name != Path.basename(path), do: fail.(".sha256 names #{name}")

  _ ->
    fail.(".sha256 does not match the cassette")
end

{:ok, _} = Application.ensure_all_started(:tama_dex)
{:ok, index} = Tama.Dex.Index.start_link(path: :memory)

imported =
  case Tama.Dex.import(index, path, sha256: sha256) do
    {:ok, imported} -> imported
    {:error, reason} -> fail.("import failed: #{inspect(reason)}")
  end

expected =
  for document <- [Composite.openapi(), Native.openapi()] do
    %{source: document["x-tama-source"], operations: map_size(document["paths"])}
  end

if imported.cassette != "opsmaru_incus", do: fail.("cassette is named #{imported.cassette}")
if imported.version != version, do: fail.("cassette version is #{imported.version}")
if imported.mode != :copy, do: fail.("the pinned import used #{imported.mode} mode")

if Enum.sort_by(imported.sources, & &1.source) != expected,
  do: fail.("sources are #{inspect(imported.sources)}")

scopes = Composite.scopes() ++ Native.scopes()

for {source, operation} <- [
      {"opsmaru_incus", "incus_instance_delete"},
      {"opsmaru_incus_native", "incus_native_delete_instance"}
    ] do
  {:ok, %{results: results}} =
    Tama.Dex.search(index, operation, scopes: scopes, source: source, cassette: "opsmaru_incus")

  if not Enum.any?(results, &(&1.operation_id == operation and &1.cassette_version == version)),
    do: fail.("#{operation} is not searchable in #{source}")
end

# A host without the pin still gets the same index, rebuilt from the documents.
{:ok, unpinned} = Tama.Dex.Index.start_link(path: :memory)

case Tama.Dex.import(unpinned, path) do
  {:ok, %{mode: :rebuild, digest: digest}} when digest == imported.digest -> :ok
  other -> fail.("unpinned import returned #{inspect(other)}")
end

IO.puts("cassette: opsmaru_incus #{version}")
IO.puts("sources: " <> Enum.map_join(expected, ", ", &"#{&1.source} (#{&1.operations})"))
IO.puts("content digest: #{imported.digest}")
IO.puts("sha256: #{sha256}")
