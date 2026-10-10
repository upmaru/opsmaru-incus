defmodule Opsmaru.Incus.Inventory do
  @moduledoc """
  Reference declaration inventory. Changes are compared independently from
  implementation evidence; generated declarations never constitute parity.
  """

  @spec diff(map(), map()) :: map()
  def diff(before, after_inventory) do
    old = by_id(before)
    new = by_id(after_inventory)
    old_ids = Map.keys(old) |> MapSet.new()
    new_ids = Map.keys(new) |> MapSet.new()
    old_sources = sources(before)
    new_sources = sources(after_inventory)

    %{
      added: MapSet.difference(new_ids, old_ids) |> Enum.sort(),
      removed: MapSet.difference(old_ids, new_ids) |> Enum.sort(),
      changed:
        MapSet.intersection(old_ids, new_ids)
        |> Enum.filter(fn id ->
          Map.take(old[id], ["signature", "build_constraints", "source"]) !=
            Map.take(new[id], ["signature", "build_constraints", "source"]) or
            old_sources[old[id]["source"]] != new_sources[new[id]["source"]]
        end)
        |> Enum.sort()
    }
  end

  defp sources(inventory),
    do: Map.new(Map.get(inventory, "sources", []), &{&1["path"], &1["sha256"]})

  defp by_id(%{"entries" => entries}) do
    result = Map.new(entries, &{Map.fetch!(&1, "id"), &1})
    if map_size(result) != length(entries), do: raise(ArgumentError, "duplicate inventory ID")
    result
  end
end
