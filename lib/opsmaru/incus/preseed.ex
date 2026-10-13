defmodule Opsmaru.Incus.Preseed do
  @moduledoc """
  Explicit native ApplyServerPreseed orchestration; never invoked at startup.

  Applies at most 128 records in native dependency order under one total
  deadline. Successful mutations are returned in `changes`; failures preserve
  that bounded journal and the native failure/accepted operation response.
  No rollback, mutation replay, trust generation or host provisioning occurs.
  This helper configures the host-selected Incus server only when explicitly
  called by the authorized host. JSON models are normalized like native typed
  input; ambiguous case aliases are rejected. YAML is not parsed here.
  """
  alias Opsmaru.Incus
  alias Opsmaru.Incus.{Error, Model, Operation, PreseedConfig}
  defstruct changes: []

  def apply(client, config, opts \\ []) do
    with :ok <- options(opts, client.connection.timeout),
         {:ok, config} <- PreseedConfig.prepare(config, client.connection.max_request_bytes) do
      state = %{
        client: client,
        deadline: now() + Keyword.get(opts, :timeout, client.connection.timeout),
        result: %__MODULE__{},
        bytes: 0
      }

      stages = [
        &server/2,
        &pools/2,
        &default_networks/2,
        &projects/2,
        &other_networks/2,
        &volumes/2,
        &profiles/2,
        &certificates/2,
        &cluster/2,
        &groups/2
      ]

      case each(state, stages, fn state, stage -> stage.(state, config) end) do
        {:ok, state} ->
          {:ok, state.result}

        {:error, error, state} ->
          {:error, %{error | response: %{completed: state.result, failure: error.response}}}
      end
    end
  end

  defp options(opts, default) do
    if Keyword.keyword?(opts) and length(opts) <= 1 and
         Keyword.keys(opts) -- [:timeout] == [] and
         is_integer(Keyword.get(opts, :timeout, default)) and
         Keyword.get(opts, :timeout, default) in 1..3_600_000,
       do: :ok,
       else: {:error, %Error{kind: :invalid_preseed_options}}
  end

  defp each(state, items, callback) do
    Enum.reduce_while(items || [], {:ok, state}, fn item, {:ok, state} ->
      case callback.(state, item) do
        {:ok, state} -> {:cont, {:ok, state}}
        error -> {:halt, error}
      end
    end)
  end

  defp request(state, method, args \\ %{}, opts \\ []) do
    remaining = state.deadline - now()

    if remaining <= 0 do
      {:error, %Error{kind: :deadline}, state}
    else
      client = %{
        state.client
        | connection: %{
            state.client.connection
            | timeout: min(state.client.connection.timeout, remaining)
          }
      }

      case execute(client, method, args, opts) do
        {:ok, response} -> record(state, method, args, response)
        {:error, error} -> {:error, error, state}
      end
    end
  end

  defp execute(client, "GetServer", %{}, []), do: Incus.raw_query(client, "GET", "/1.0")
  defp execute(client, method, args, opts), do: Incus.call(client, method, args, opts)

  defp record(state, "Get" <> _, _, response), do: {:ok, response, state}

  defp record(state, method, args, response) do
    bytes = state.bytes + :erlang.external_size(response)

    if bytes <= state.client.connection.max_response_bytes do
      change = %{method: method, arguments: args, response: response}
      result = %{state.result | changes: state.result.changes ++ [change]}
      {:ok, response, %{state | result: result, bytes: bytes}}
    else
      {:error,
       %Error{kind: :preseed_result_limit, response: response, operation: response.operation},
       state}
    end
  end

  defp server(state, config) do
    if map_size(config["config"] || %{}) == 0 do
      {:ok, state}
    else
      with {:ok, response, state} <- request(state, "GetServer"),
           {:ok, body} <- writable(response),
           {:ok, _, state} <-
             request(state, "UpdateServer", %{}, body: merge(body, config), etag: response.etag) do
        {:ok, state}
      else
        {:error, error, state} -> {:error, error, state}
        {:error, error} -> {:error, error, state}
      end
    end
  end

  defp pools(state, config), do: listed(state, config["storage_pools"], :pool)
  defp projects(state, config), do: listed(state, config["projects"], :project)
  defp listed(state, items, _) when items in [nil, []], do: {:ok, state}

  defp listed(state, items, kind) do
    method = if kind == :pool, do: "GetStoragePoolNames", else: "GetProjectNames"

    with {:ok, response, state} <- request(state, method) do
      each(state, items, fn state, item ->
        if item["name"] in response.metadata,
          do: update(state, item, kind),
          else: create(state, item, kind)
      end)
    end
  end

  defp default_networks(state, config), do: networks(state, config, true)
  defp other_networks(state, config), do: networks(state, config, false)

  defp networks(state, config, default?) do
    items =
      Enum.filter(
        config["networks"] || [],
        &(PreseedConfig.project(&1) == "default" == default?)
      )

    each(state, items, &upsert(&1, &2, :network))
  end

  defp volumes(state, config),
    do: each(state, config["storage_volumes"], &upsert(&1, &2, :volume))

  defp profiles(state, config), do: each(state, config["profiles"], &upsert(&1, &2, :profile))

  defp certificates(state, config),
    do: each(state, config["certificates"], &create(&1, &2, :certificate))

  defp upsert(state, item, kind) do
    case read(state, item, kind) do
      {:ok, response, state} -> update_response(state, item, kind, response)
      {:error, _, state} -> create(state, item, kind)
    end
  end

  defp update(state, item, kind) do
    with {:ok, response, state} <- read(state, item, kind),
         do: update_response(state, item, kind, response)
  end

  defp read(state, item, kind) do
    {get, _, _, _, args} = resource(kind, item)

    request(selected(state, kind, item), get, args)
    |> restore_client(state)
  end

  defp update_response(state, item, kind, response) do
    with :ok <- compatible(kind, item, response),
         {:ok, body} <- writable(response) do
      {_, _, put, _, args} = resource(kind, item)
      body = merge(body, item)
      mutate(state, item, kind, put, args, body, response.etag)
    else
      {:error, %Error{} = error} -> {:error, error, state}
    end
  end

  defp compatible(kind, item, response) when kind in [:pool, :volume] do
    key = if kind == :pool, do: "driver", else: "type"
    expected = if kind == :pool, do: item[key], else: PreseedConfig.volume_type(item)

    if response.metadata.data[key] == expected,
      do: :ok,
      else: {:error, %Error{kind: :preseed_conflict, response: response}}
  end

  defp compatible(_, _, _), do: :ok

  defp create(state, item, kind) do
    {_, post, _, type, args} = resource(kind, item)
    args = Map.drop(args, ["name", "volType"])

    item =
      if kind == :volume, do: Map.put(item, "type", PreseedConfig.volume_type(item)), else: item

    case PreseedConfig.project_body(type, item) do
      {:ok, body} -> mutate(state, item, kind, post, args, body, nil)
      {:error, error} -> {:error, error, state}
    end
  end

  defp mutate(state, item, kind, method, args, body, etag) do
    case request(selected(state, kind, item), method, args, body: body, etag: etag)
         |> restore_client(state) do
      {:ok, _, state} -> {:ok, state}
      error -> error
    end
  end

  defp selected(state, kind, item) when kind in [:network, :volume, :profile],
    do: %{state | client: Incus.project(state.client, PreseedConfig.project(item))}

  defp selected(state, _, _), do: state

  defp restore_client({:ok, response, changed}, state),
    do: {:ok, response, %{changed | client: state.client}}

  defp restore_client({:error, error, changed}, state),
    do: {:error, error, %{changed | client: state.client}}

  defp merge(body, item) do
    body = Map.put(body, "config", Map.merge(body["config"] || %{}, item["config"] || %{}))

    body =
      if item["description"] in [nil, ""],
        do: body,
        else: Map.put(body, "description", item["description"])

    if Map.has_key?(body, "devices") do
      devices =
        Map.merge(body["devices"] || %{}, item["devices"] || %{}, fn _, current, target ->
          Map.merge(current, target)
        end)

      Map.put(body, "devices", devices)
    else
      body
    end
  end

  defp writable(response) do
    result =
      case response.metadata do
        %Model{} = model -> Model.writable(model) |> writable_data()
        data when is_map(data) -> Model.decode("Server", data) |> writable_model()
        _ -> {:error, %Error{kind: :invalid_model}}
      end

    case result do
      {:error, error} -> {:error, %{error | response: response}}
      result -> result
    end
  end

  defp writable_data({:ok, model}),
    do: PreseedConfig.project_body(model.type, model.data)

  defp writable_data(_), do: {:error, %Error{kind: :invalid_model}}
  defp writable_model({:ok, model}), do: Model.writable(model) |> writable_data()
  defp writable_model(_), do: {:error, %Error{kind: :invalid_model}}

  defp cluster(state, %{"cluster" => %{"enabled" => true} = config}) do
    with {:ok, response, state} <- request(state, "GetCluster") do
      if response.metadata.data["enabled"] == true do
        {:ok, state}
      else
        enable_cluster(state, config, response.etag)
      end
    end
  end

  defp cluster(state, _), do: {:ok, state}

  defp enable_cluster(state, config, etag) do
    with {:ok, body} <- PreseedConfig.project_body("ClusterPut", config),
         {:ok, response, state} <- request(state, "UpdateCluster", %{}, body: body, etag: etag) do
      wait_cluster(state, response)
    else
      {:error, error, state} -> {:error, error, state}
      {:error, error} -> {:error, error, state}
    end
  end

  defp wait_cluster(state, response) do
    remaining = state.deadline - now()
    client = %{state.client | connection: response.connection}

    with true <- remaining > 0,
         {:ok, operation} <- Operation.from_response(client, response),
         {:ok, _} <- Operation.wait(operation, timeout: remaining) do
      {:ok, state}
    else
      false ->
        {:error, %Error{kind: :deadline, response: response, operation: response.operation},
         state}

      {:error, error} ->
        {:error, error, state}
    end
  end

  defp groups(state, config), do: each(state, config["cluster_groups"], &group/2)

  defp group(state, item) do
    case request(state, "GetClusterGroup", %{"name" => item["name"]}) do
      {:ok, response, state} ->
        item =
          if is_nil(item["members"]),
            do: Map.put(item, "members", response.metadata.data["members"]),
            else: item

        case PreseedConfig.project_body("ClusterGroupPut", item) do
          {:ok, body} ->
            mutate(
              state,
              item,
              :group,
              "UpdateClusterGroup",
              %{"name" => item["name"]},
              body,
              response.etag
            )

          {:error, error} ->
            {:error, error, state}
        end

      {:error, _, state} ->
        create(state, item, :group)
    end
  end

  defp resource(:pool, item),
    do:
      {"GetStoragePool", "CreateStoragePool", "UpdateStoragePool", "StoragePoolsPost",
       %{"name" => item["name"]}}

  defp resource(:project, item),
    do:
      {"GetProject", "CreateProject", "UpdateProject", "ProjectsPost", %{"name" => item["name"]}}

  defp resource(:network, item),
    do:
      {"GetNetwork", "CreateNetwork", "UpdateNetwork", "NetworksPost", %{"name" => item["name"]}}

  defp resource(:profile, item),
    do:
      {"GetProfile", "CreateProfile", "UpdateProfile", "ProfilesPost", %{"name" => item["name"]}}

  defp resource(:volume, item),
    do:
      {"GetStoragePoolVolume", "CreateStoragePoolVolume", "UpdateStoragePoolVolume",
       "StorageVolumesPost",
       %{
         "pool" => item["Pool"],
         "volType" => PreseedConfig.volume_type(item),
         "name" => item["name"]
       }}

  defp resource(:certificate, _), do: {nil, "CreateCertificate", nil, "CertificatesPost", %{}}

  defp resource(:group, item),
    do:
      {"GetClusterGroup", "CreateClusterGroup", "UpdateClusterGroup", "ClusterGroupsPost",
       %{"name" => item["name"]}}

  defp now, do: System.monotonic_time(:millisecond)
end

defimpl Inspect, for: Opsmaru.Incus.Preseed do
  def inspect(_, _), do: "#Opsmaru.Incus.Preseed<bounded native changes redacted>"
end
