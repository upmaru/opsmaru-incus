defmodule Opsmaru.Incus.ModelURL do
  @moduledoc "Pure native resource URL helpers; returns relative paths and never contacts advertised addresses."
  alias Opsmaru.Incus.Model

  @collections %{
    "Certificate" => "certificates",
    "Image" => "images",
    "Instance" => "instances",
    "NetworkACL" => "network-acls",
    "Profile" => "profiles",
    "Project" => "projects"
  }
  @types Map.keys(@collections) ++ ["StorageBucket", "StorageBucketKey", "StorageVolume"]

  def resource(model, opts \\ [])

  def resource(%Model{type: type, data: data}, opts) when type in @types and is_map(data) do
    version = if Keyword.keyword?(opts), do: Keyword.get(opts, :version, "1.0"), else: nil

    with true <- Keyword.keyword?(opts) and Keyword.keys(opts) -- allowed(type) == [],
         {:ok, _} <- Model.decode(type, data),
         true <- valid?(version) and version != "",
         true <- Enum.all?(opts, fn {_, value} -> valid?(value) end),
         {:ok, parts, project, target} <- parts(type, data, version, opts),
         true <- (is_nil(project) or valid?(project)) and (is_nil(target) or valid?(target)),
         true <- Enum.all?(parts, &valid?/1) do
      query = []
      query = if project in [nil, "", "default"], do: query, else: [{"project", project} | query]
      query = if target in [nil, "", "none"], do: query, else: [{"target", target} | query]
      path = "/" <> Enum.map_join(parts, "/", &escape/1)
      {:ok, path <> if(query == [], do: "", else: "?" <> URI.encode_query(Enum.sort(query)))}
    else
      _ -> {:error, :invalid_model_url}
    end
  end

  def resource(_, _), do: {:error, :unsupported_model_helper}

  def parent_snapshot_name(value) when is_binary(value) and byte_size(value) <= 1024 do
    case String.split(value, "/", parts: 2) do
      [parent, snapshot] -> {parent, snapshot, true}
      [parent] -> {parent, "", false}
    end
  end

  defp allowed(type) when type in ["Certificate", "Project"], do: [:version]
  defp allowed("StorageVolume"), do: [:version, :pool]
  defp allowed("StorageBucket"), do: [:version, :pool, :project]
  defp allowed("StorageBucketKey"), do: [:version, :pool, :project, :bucket]
  defp allowed(_), do: [:version, :project]

  defp parts(type, data, version, opts) when is_map_key(@collections, type) do
    name =
      if type in ["Certificate", "Image"], do: data["fingerprint"] || "", else: data["name"] || ""

    {:ok, [version, @collections[type], name], opts[:project], nil}
  end

  defp parts("StorageBucket", data, version, opts),
    do:
      {:ok, [version, "storage-pools", opts[:pool], "buckets", data["name"] || ""],
       opts[:project], data["location"]}

  defp parts("StorageBucketKey", data, version, opts),
    do:
      {:ok,
       [
         version,
         "storage-pools",
         opts[:pool],
         "buckets",
         opts[:bucket],
         "keys",
         data["name"] || ""
       ], opts[:project], nil}

  defp parts("StorageVolume", data, version, opts) do
    name = data["name"] || ""

    if valid?(name) do
      {parent, snapshot, snapshot?} = parent_snapshot_name(name)
      parts = [version, "storage-pools", opts[:pool], "volumes", data["type"] || "", parent]

      {:ok, parts ++ if(snapshot?, do: ["snapshots", snapshot], else: []), data["project"],
       data["location"]}
    else
      {:error, :invalid_model_url}
    end
  end

  defp valid?(value), do: is_binary(value) and byte_size(value) <= 1024

  defp escape(value),
    do: URI.encode(value, fn char -> URI.char_unreserved?(char) or char in ~c"$&+:=@" end)
end
