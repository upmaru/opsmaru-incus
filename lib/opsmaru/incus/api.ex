defmodule Opsmaru.Incus.API do
  @moduledoc false
  alias Opsmaru.Incus.{Error, Model}
  @external_resource Path.expand("../../../priv/incus/methods.json", __DIR__)
  @methods Jason.decode!(File.read!(@external_resource))["methods"] |> Map.new(&{&1["name"], &1})

  def methods, do: Map.keys(@methods) |> Enum.sort()

  def call(client, name, args, opts) do
    with {:ok, method} <- fetch(name),
         :ok <- extension(client, method["extension"]),
         :ok <- arguments(method, args, opts),
         {:ok, body} <- body(method, opts),
         :ok <- guards(client, method["guards"], body),
         {:ok, path, body} <- native_request(client, method, args, body),
         {:ok, response} <-
           Opsmaru.Incus.raw_query(client, method["verb"], path, Keyword.merge(opts, body: body)) do
      case decode(method, response, path) do
        {:error, %Error{} = error} ->
          decode_error(method, response, error.kind)

        {:error, kind} ->
          decode_error(method, response, kind)

        result ->
          result
      end
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, kind} -> {:error, %Error{kind: kind}}
    end
  end

  defp decode_error(method, response, kind) do
    kind = if method["verb"] in ["GET", "HEAD"], do: kind, else: :uncertain
    {:error, %Error{kind: kind, response: response, operation: response.operation}}
  end

  defp fetch(name) do
    case Map.fetch(@methods, name) do
      {:ok, definition} -> {:ok, definition}
      :error -> {:error, :unimplemented_method}
    end
  end

  defp extension(_, nil), do: :ok

  defp extension(client, values) when is_list(values) do
    Enum.reduce_while(values, :ok, fn value, _ ->
      case extension(client, value) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp extension(client, value), do: Opsmaru.Incus.require_extension(client, value)

  defp arguments(method, args, opts) do
    if is_map(args) and Enum.sort(Map.keys(args)) == Enum.sort(method["params"]) and
         Keyword.keys(opts) -- [:body, :etag] == [] and
         Enum.all?(args, fn {name, value} -> valid_argument?(name, value) end) and
         wait_secret?(method, args) and conditional?(method, args, opts),
       do: :ok,
       else: {:error, :invalid_arguments}
  end

  defp conditional?(%{"conditional" => true}, args, opts),
    do: conditional?(%{"result" => "empty_sync"}, args, opts)

  defp conditional?(%{"result" => "empty_sync"}, args, opts),
    do:
      Enum.all?(args, fn {_, value} -> value != "" end) and is_binary(opts[:etag]) and
        byte_size(opts[:etag]) in 1..1024 and
        length(opts) == length(Enum.uniq(Keyword.keys(opts)))

  defp conditional?(_, _, _), do: true

  # Daemon wait secrets are lowercase hex; empty or arbitrary values are approved
  # exclusions and must not silently become a different (plain) wait request.
  defp wait_secret?(%{"name" => "GetOperationWaitSecret"}, %{"secret" => secret}),
    do: secret =~ ~r/\A[0-9a-f]+\z/

  defp wait_secret?(_, _), do: true

  defp valid_argument?("force", value), do: is_boolean(value)
  defp valid_argument?("timeout", value), do: is_integer(value) and value in 0..3600

  defp valid_argument?("filters", value),
    do:
      is_list(value) and length(value) <= 128 and
        Enum.all?(value, &(is_binary(&1) and byte_size(&1) <= 1024))

  defp valid_argument?(_, value), do: is_binary(value) and byte_size(value) <= 1024

  defp body(%{"body" => nil}, opts) do
    if is_nil(opts[:body]), do: {:ok, nil}, else: {:error, :unexpected_body}
  end

  defp body(%{"body" => type} = method, opts) do
    with data when is_map(data) <- Model.encode(opts[:body]),
         {:ok, model} <- Model.decode(type, data) do
      data =
        Enum.reduce(Map.get(method, "defaults", %{}), model.data, fn {key, value}, data ->
          if data[key] in [nil, ""], do: Map.put(data, key, value), else: data
        end)

      {:ok, data}
    else
      _ -> {:error, :invalid_body}
    end
  end

  defp guards(_, [], _), do: :ok

  defp guards(client, [guard | rest], body) do
    value = get_in(body || %{}, String.split(guard["field"], "."))

    case guard do
      %{"equals" => expected} ->
        if value == expected or (expected == false and is_nil(value)),
          do: guards(client, rest, body),
          else: {:error, :invalid_body}

      %{"extension" => required} ->
        if value not in Map.get(guard, "exclude", [nil, false, "", [], %{}, 0]) and
             (not Map.has_key?(guard, "if_equals") or value == guard["if_equals"]) do
          with :ok <- extension(client, required), do: guards(client, rest, body)
        else
          guards(client, rest, body)
        end
    end
  end

  defp path(method, args, body) do
    path =
      Enum.reduce(args, method["path"], fn {key, value}, path ->
        placeholder = "{" <> key <> "}"

        if String.contains?(path, placeholder),
          do: String.replace(path, placeholder, escape(value)),
          else: path
      end)

    path =
      Enum.reduce(Map.get(method, "body_path", %{}), path, fn {key, field}, path ->
        String.replace(path, "{" <> key <> "}", escape((body || %{})[field]))
      end)

    path =
      if String.contains?(path, "{body.type}"),
        do: String.replace(path, "{body.type}", escape((body || %{})["type"] || "")),
        else: path

    query =
      Map.new(method["query"], fn {key, value} ->
        resolved = resolve_query(value, args)
        {key, query_value(key, resolved)}
      end)
      |> Map.reject(fn {key, value} ->
        key in ["instance-type", "secret", "force"] and value == ""
      end)

    {:ok, path <> if(map_size(query) == 0, do: "", else: "?" <> URI.encode_query(query))}
  rescue
    _ -> {:error, :invalid_arguments}
  end

  defp resolve_query("{filters}", args), do: filters(args["filters"])

  defp resolve_query(value, args) do
    if String.starts_with?(value, "{"),
      do: Map.fetch!(args, value |> String.trim_leading("{") |> String.trim_trailing("}")),
      else: value
  end

  defp query_value("force", value), do: if(value, do: "1", else: "")
  defp query_value(_, value), do: value

  defp native_request(client, %{"name" => "MigrateStoragePoolVolume"} = method, args, body) do
    case String.split(body["name"] || "", "/") do
      [parent, snapshot] when parent != "" and snapshot != "" ->
        with :ok <- extension(client, "storage_api_remote_volume_snapshot_copy") do
          path =
            "/1.0/storage-pools/" <>
              escape(args["pool"]) <>
              "/volumes/custom/" <> escape(parent) <> "/snapshots/" <> escape(snapshot)

          {:ok, path,
           %{"name" => snapshot, "migration" => body["migration"], "target" => body["target"]}}
        end

      [_] ->
        with {:ok, path} <- path(method, args, body), do: {:ok, path, body}

      _ ->
        {:error, :invalid_body}
    end
  end

  defp native_request(_, method, args, body),
    do: with({:ok, path} <- path(method, args, body), do: {:ok, path, body})

  defp escape(value) when is_binary(value) and byte_size(value) in 0..1024,
    do: URI.encode(value, &URI.char_unreserved?/1)

  # filters never appear in a path.
  defp escape(value) when is_list(value), do: ""

  defp filters(values) when is_list(values) do
    values
    |> Enum.flat_map(fn value ->
      case String.split(value, "=", parts: 2) do
        [key, value] -> [key <> " eq " <> value]
        [_] -> []
      end
    end)
    |> Enum.join(" and ")
  end

  defp decode(%{"response_status" => expected}, %{http_status: actual}, _)
       when actual != expected,
       do: {:error, :invalid_response}

  defp decode(%{"result" => "empty_sync"}, response, _) do
    if response.http_status == 200 and response.type == "sync" and
         response.status_code == 200 and response.metadata == %{} and response.operation == "",
       do: {:ok, response},
       else: {:error, :invalid_response}
  end

  defp decode(%{"result" => "sync"}, response, _), do: {:ok, response}

  defp decode(%{"result" => "strings"}, response, _) when is_list(response.metadata) do
    if Enum.all?(response.metadata, &is_binary/1),
      do: {:ok, response},
      else: {:error, :invalid_model}
  end

  defp decode(%{"result" => "project_urls"}, response, path) when is_list(response.metadata) do
    prefix = URI.decode(URI.parse(path).path) <> "/"

    names =
      Enum.reduce(response.metadata, %{}, fn url, acc ->
        uri = URI.parse(url)
        decoded = URI.decode(uri.path || "")
        true = String.starts_with?(decoded, prefix)
        name = String.replace_prefix(decoded, prefix, "")
        project = URI.decode_query(uri.query || "")["project"] || "default"
        Map.update(acc, project, [name], &(&1 ++ [name]))
      end)

    {:ok, %{response | metadata: names}}
  rescue
    _ -> {:error, :invalid_model}
  end

  defp decode(%{"result" => "grouped_list"} = method, response, path)
       when is_map(response.metadata) do
    values = Map.values(response.metadata)

    if Enum.all?(values, &is_list/1),
      do:
        decode(%{method | "result" => "list"}, %{response | metadata: List.flatten(values)}, path),
      else: {:error, :invalid_model}
  end

  defp decode(%{"result" => "project_names"}, response, _) when is_list(response.metadata) do
    if Enum.all?(response.metadata, fn instance ->
         is_map(instance) and is_binary(instance["project"]) and is_binary(instance["name"])
       end) do
      names =
        Enum.reduce(response.metadata, %{}, fn instance, acc ->
          Map.update(acc, instance["project"], [instance["name"]], &(&1 ++ [instance["name"]]))
        end)

      {:ok, %{response | metadata: names}}
    else
      {:error, :invalid_model}
    end
  end

  defp decode(%{"result" => "operation"}, response, _) do
    if response.type == "async" and is_binary(response.operation) and response.operation != "" and
         is_map(response.metadata) do
      case Model.decode("Operation", response.metadata) do
        {:ok, model} -> {:ok, %{response | metadata: model}}
        _ -> {:error, %Error{kind: :uncertain, response: response, operation: response.operation}}
      end
    else
      {:error, %Error{kind: :uncertain, response: response, operation: response.operation}}
    end
  end

  defp decode(%{"result" => "model", "model" => type}, response, _) do
    with {:ok, model} <- Model.decode(type, response.metadata),
         do: {:ok, %{response | metadata: model}}
  end

  defp decode(%{"result" => "list", "model" => type}, response, _)
       when is_list(response.metadata) do
    Enum.reduce_while(response.metadata, {:ok, []}, fn item, {:ok, acc} ->
      case Model.decode(type, item) do
        {:ok, model} -> {:cont, {:ok, [model | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, models} -> {:ok, %{response | metadata: Enum.reverse(models)}}
      error -> error
    end
  end

  defp decode(%{"result" => "names"}, response, path) when is_list(response.metadata) do
    prefix = URI.parse(path).path <> "/"

    names =
      Enum.map(response.metadata, fn url ->
        uri = URI.parse(url)
        decoded = URI.decode(uri.path || "")
        [_before, name] = String.split(decoded, URI.decode(prefix), parts: 2)
        name
      end)

    {:ok, %{response | metadata: names}}
  rescue
    _ -> {:error, :invalid_model}
  end

  defp decode(_, _, _), do: {:error, :invalid_model}
end
