defmodule Opsmaru.Incus.SimpleStreams.Catalog do
  @moduledoc false
  alias Opsmaru.Incus.{Model, NativeInput}

  @architectures %{
    "i686" => ~w(i386 i586 386 x86 generic_32),
    "x86_64" => ~w(amd64 generic_64 x86_64_v1 x86_64_v2 x86_64_v3 x86_64_v4),
    "armv6l" => ~w(armel arm),
    "armv7l" => ~w(armhf armhfp armv7a_hardfp armv7 armv7a_vfpv3_hardfp),
    "armv8l" => [],
    "aarch64" => ~w(arm64 arm64_generic),
    "ppc" => ~w(powerpc),
    "ppc64" => ~w(powerpc64),
    "ppc64le" => ~w(ppc64el),
    "s390x" => [],
    "mips" => ~w(mipsel mipsle),
    "mips64" => ~w(mips64el mips64le),
    "riscv32" => [],
    "riscv64" => [],
    "loongarch64" => ~w(loong64)
  }
  @roots ~w(squashfs root.tar.xz disk-kvm.img uefi1.img disk1.img)
  @hashes %{
    "squashfs" => "combined_squashfs_sha256",
    "root.tar.xz" => "combined_rootxz_sha256",
    "disk-kvm.img" => "combined_disk-kvm-img_sha256",
    "uefi1.img" => "combined_uefi1-img_sha256",
    "disk1.img" => "combined_disk1-img_sha256"
  }
  @personalities %{
    "x86_64" => ["i686"],
    "armv7l" => ["armv6l"],
    "armv8l" => ~w(armv6l armv7l),
    "aarch64" => ~w(armv6l armv7l armv8l),
    "ppc64" => ["ppc"],
    "mips64" => ["mips"]
  }

  def architecture(value) do
    case Enum.find(@architectures, fn {name, aliases} -> value == name or value in aliases end) do
      {name, _} -> {:ok, name}
      nil -> :error
    end
  end

  def build(products, native) do
    entries = Enum.flat_map(products, &product_entries/1) |> Enum.sort(&before?/2)
    {images, aliases} = aliases(entries, native)
    files = Map.new(entries, &{&1.image["fingerprint"], &1.files})
    {:ok, %{images: images, aliases: aliases, files: files, architecture: native}}
  rescue
    _ -> {:error, :invalid_simplestreams_catalog}
  end

  defp product_entries(product) do
    with {:ok, architecture} <- architecture(product["arch"]),
         versions when is_map(versions) <- product["versions"] do
      Enum.flat_map(versions, fn {serial, version} ->
        version_entries(product, serial, version, architecture)
      end)
    else
      _ -> []
    end
  end

  defp version_entries(product, serial, version, architecture) do
    with true <- is_binary(serial) and byte_size(serial) >= 8,
         <<year::binary-size(4), month::binary-size(2), day::binary-size(2), _::binary>> <- serial,
         {:ok, date} <- Date.from_iso8601(year <> "-" <> month <> "-" <> day) do
      items = Map.values(version["items"] || %{})
      Enum.flat_map(items, &item_entries(product, serial, version, architecture, date, &1, items))
    else
      _ -> []
    end
  end

  defp item_entries(product, serial, version, architecture, date, meta, items) do
    case meta["ftype"] do
      "incus_combined.tar.gz" ->
        image(product, serial, version, architecture, date, meta, nil)

      "incus.tar.xz" ->
        items
        |> Enum.filter(&(&1["ftype"] in @roots))
        |> Enum.flat_map(&image(product, serial, version, architecture, date, meta, &1))

      _ ->
        []
    end
  end

  defp image(product, serial, version, architecture, date, meta, root) do
    fingerprint = fingerprint(meta, root)

    if fingerprint in [nil, ""] or meta["path"] in [nil, ""] do
      []
    else
      properties = properties(product, serial, version, root)
      names = alias_names(product)
      data = image_data(product, architecture, date, meta, root, fingerprint, properties)

      files = %{"meta" => file(meta)}
      files = if root, do: Map.put(files, "root", file(root)), else: files
      files = Map.merge(files, deltas(product, version, root))
      [%{image: data, names: names, files: files}]
    end
  end

  defp properties(product, serial, version, root) do
    label = version["label"] || ""

    description =
      "#{product["os"] || ""} #{product["release_title"] || ""} #{product["arch"] || ""}"

    description = description <> if(label == "", do: "", else: " (#{label})") <> " (#{serial})"

    properties = %{
      "os" => product["os"] || "",
      "release" => product["release"] || "",
      "version" => product["version"] || "",
      "architecture" => product["arch"],
      "label" => label,
      "serial" => serial,
      "description" => description,
      "variant" => product["variant"] || "",
      "type" => if(root, do: root["ftype"], else: "tar.gz")
    }

    requirements =
      Map.new(product["requirements"] || %{}, fn {key, value} ->
        {"requirements." <> key, value}
      end)

    Map.merge(properties, requirements) |> Map.reject(fn {_, value} -> value == "" end)
  end

  defp alias_names(%{"aliases" => names}) when is_binary(names) and names != "",
    do: String.split(names, ",")

  defp alias_names(_), do: []

  defp image_data(product, architecture, date, meta, root, fingerprint, properties) do
    %{
      "architecture" => architecture,
      "public" => true,
      "fingerprint" => fingerprint,
      "size" => signed_size((meta["size"] || 0) + if(root, do: root["size"] || 0, else: 0)),
      "created_at" => Date.to_iso8601(date) <> "T00:00:00Z",
      "uploaded_at" => Date.to_iso8601(date) <> "T00:00:00Z",
      "expires_at" => expiry(product["support_eol"]),
      "filename" => List.last(String.split(meta["path"], "/")),
      "properties" => properties,
      "type" => image_type(meta, root)
    }
  end

  defp signed_size(size),
    do:
      Integer.mod(size + 9_223_372_036_854_775_808, 18_446_744_073_709_551_616) -
        9_223_372_036_854_775_808

  defp image_type(_, %{"ftype" => type}) when type in ~w(disk1.img disk-kvm.img uefi1.img),
    do: "virtual-machine"

  defp image_type(%{"combined_type" => "virtual-machine"}, nil), do: "virtual-machine"
  defp image_type(_, _), do: "container"

  defp fingerprint(meta, nil), do: meta["sha256"]

  defp fingerprint(meta, %{"ftype" => "root.tar.xz"}) do
    if meta["combined_rootxz_sha256"] in [nil, ""],
      do: meta["combined_sha256"],
      else: meta["combined_rootxz_sha256"]
  end

  defp fingerprint(meta, root), do: meta[@hashes[root["ftype"]]]

  defp expiry(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> Date.to_iso8601(date) <> "T00:00:00Z"
      _ -> "1970-01-01T00:00:00Z"
    end
  end

  defp expiry(_), do: "1970-01-01T00:00:00Z"

  defp file(item),
    do: %{path: item["path"] || "", sha256: item["sha256"] || "", size: item["size"] || 0}

  defp deltas(product, version, %{"ftype" => type}) when type in ["squashfs", "disk-kvm.img"] do
    for item <- Map.values(version["items"] || %{}),
        item["ftype"] == type <> ".vcdiff",
        base = get_in(product, ["versions", item["delta_base"], "items"]),
        is_map(base),
        meta <- Map.values(base),
        meta["ftype"] == "incus.tar.xz",
        hash = meta["combined_squashfs_sha256"],
        hash not in [nil, ""],
        into: %{},
        do: {"root.delta-" <> hash, file(item)}
  end

  defp deltas(_, _, _), do: %{}

  # Preserve the pinned preference (including its default score for tar.gz).
  defp before?(left, right) do
    a = left.image["properties"]
    b = right.image["properties"]
    key = Enum.find(~w(os release variant serial architecture), &(a[&1] != b[&1]))

    cond do
      key && a[key] in [nil, ""] -> false
      key == "serial" -> a[key] > b[key]
      key -> (a[key] || "") < (b[key] || "")
      true -> score(a["type"]) < score(b["type"])
    end
  end

  defp score(type), do: Enum.find_index(@roots, &(&1 == type)) || 0

  defp aliases(entries, native) do
    {images, aliases, _} =
      Enum.reduce(entries, {[], [], MapSet.new()}, fn entry, acc ->
        alias_image(entry, native, acc)
      end)

    {Enum.reverse(images), Enum.reverse(aliases)}
  end

  defp alias_image(entry, native, {images, aliases, seen}) do
    image = entry.image

    {names, aliases, seen} =
      Enum.reduce(entry.names, {[], aliases, seen}, fn name, acc ->
        acc = add_alias(image, name, image["architecture"] == native, acc)
        add_alias(image, name <> "/" <> image["properties"]["architecture"], true, acc)
      end)

    {:ok, data} =
      NativeInput.cast(
        "Image",
        Map.put(image, "aliases", if(names == [], do: nil, else: Enum.reverse(names)))
      )

    {:ok, model} = Model.decode("Image", data)
    {[model | images], aliases, seen}
  end

  defp add_alias(image, name, include, {names, aliases, seen}) do
    key = {name, image["type"], image["architecture"]}

    if MapSet.member?(seen, key) do
      {names, aliases, seen}
    else
      {:ok, data} =
        NativeInput.cast("ImageAliasesEntry", %{
          "name" => name,
          "type" => image["type"],
          "target" => image["fingerprint"]
        })

      {:ok, model} = Model.decode("ImageAliasesEntry", data)
      names = if include, do: [%{"name" => name} | names], else: names

      {names, [%{model: model, architecture: image["architecture"]} | aliases],
       MapSet.put(seen, key)}
    end
  end

  def preferred_aliases(catalog) do
    Enum.sort_by(catalog.aliases, fn alias ->
      cond do
        alias.architecture == catalog.architecture -> 0
        alias.architecture in Map.get(@personalities, catalog.architecture, []) -> 1
        true -> 2
      end
    end)
  end
end
