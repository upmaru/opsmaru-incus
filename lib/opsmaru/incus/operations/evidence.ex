defmodule Opsmaru.Incus.Operations.Evidence do
  @moduledoc """
  Client evidence behind each operation, read from the ledgers at compile time.

  A requirement is a native method name (`"GetInstances"`), a helper
  (`"helper:connect"`) or a streaming contract (`"stream:S01"`). It has
  evidence only when every endpoint row mapping it is behavior-complete under a
  completion record (a stream contract must be certified) and its Go coverage
  entry, where one exists, names an implementation and evidence files. Tool
  results never feed back into these ledgers.
  """
  @inventory_path Path.expand("../../../../priv/incus/endpoint-inventory.json", __DIR__)
  @coverage_path Path.expand("../../../../priv/incus/coverage.json", __DIR__)
  @external_resource @inventory_path
  @external_resource @coverage_path

  inventory = Jason.decode!(File.read!(@inventory_path))
  coverage = Jason.decode!(File.read!(@coverage_path))

  rows = fn key, name ->
    for row <- inventory["entries"] ++ inventory["supplemental_server_entries"],
        name in Map.get(row, key, []),
        do: %{
          "pair" => row["pair"],
          "complete" => row["behavior_complete"] == true and is_binary(row["completion_record"]),
          "completion_record" => row["completion_record"]
        }
  end

  go =
    Map.new(coverage["entries"], fn entry ->
      {entry["id"],
       %{
         "id" => entry["id"],
         "status" => entry["status"],
         "implementation" => entry["elixir"],
         "evidence" => entry["evidence"]
       }}
    end)

  @streams Map.new(inventory["stream_contracts"], &{&1["id"], &1})

  @methods inventory["entries"]
           |> Enum.flat_map(&Map.get(&1, "methods", []))
           |> Enum.uniq()
           |> Map.new(fn method ->
             {method,
              %{
                "rows" => rows.("methods", method),
                "go" => go["client/method/ProtocolIncus." <> method]
              }}
           end)

  @helpers inventory["helpers"]
           |> Map.keys()
           |> Map.new(fn helper ->
             {helper,
              %{
                "rows" => rows.("helpers", helper),
                "client" =>
                  Enum.map_join(inventory["helpers"][helper]["client"], ".", &to_string/1),
                "evidence" =>
                  Enum.filter(
                    inventory["helpers"][helper]["evidence"],
                    &String.ends_with?(&1, ".exs")
                  )
              }}
           end)

  @doc "Evidence for one requirement: `{:ok, record}` or `{:error, reason}`."
  def lookup("helper:" <> helper) do
    case Map.fetch(@helpers, helper) do
      {:ok, %{"rows" => [_ | _] = rows} = record} ->
        complete(rows, record, record["evidence"] != [])

      _ ->
        {:error, :no_helper_evidence}
    end
  end

  def lookup("stream:" <> id) do
    case Map.fetch(@streams, id) do
      {:ok, %{"status" => "certified", "completion_record" => record} = stream}
      when is_binary(record) ->
        {:ok, %{"stream" => id, "completion_record" => record, "evidence" => stream["evidence"]}}

      _ ->
        {:error, :stream_not_certified}
    end
  end

  def lookup(method) when is_binary(method) do
    case Map.fetch(@methods, method) do
      {:ok, %{"rows" => [_ | _] = rows, "go" => go} = record} ->
        go_ok? =
          is_nil(go) or
            (go["status"] in ["partial", "complete"] and is_binary(go["implementation"]) and
               go["evidence"] != [])

        complete(rows, record, go_ok?)

      _ ->
        {:error, :no_method_evidence}
    end
  end

  def lookup(_), do: {:error, :no_method_evidence}

  defp complete(rows, record, ok?) do
    cond do
      not Enum.all?(rows, & &1["complete"]) -> {:error, :endpoint_incomplete}
      not ok? -> {:error, :no_client_evidence}
      true -> {:ok, record}
    end
  end

  @doc "Requirements among `requirements` that lack evidence."
  def missing(requirements), do: Enum.reject(requirements, &match?({:ok, _}, lookup(&1)))
end
