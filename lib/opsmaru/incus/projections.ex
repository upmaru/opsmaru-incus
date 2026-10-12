defmodule Opsmaru.Incus.Projections do
  @moduledoc """
  Bounded pure native server-filter and event-log projections. Results are typed
  data for the host; this module never writes logs or authorizes disclosure.
  Filtering matches the pinned native suffix heuristic, not a general secret
  detector. Original lossless models remain unchanged.
  """
  alias Opsmaru.Incus.{Error, Model, Response, Server}

  def filtered_server(%Server{raw: raw}), do: filtered_server(raw)
  def filtered_server(%Model{type: "Server", data: raw}), do: filtered_server(raw)

  def filtered_server(raw) when is_map(raw) or is_nil(raw) do
    with {:ok, server} <- project("Server", raw) do
      filtered =
        server.data
        |> Map.put("api_extensions_count", length(server.data["api_extensions"] || []))
        |> Map.put("api_extensions", nil)
        |> Map.update!("environment", &Map.put(&1, "certificate", ""))
        |> Map.update!("config", &filter_config/1)

      Model.decode("ServerFiltered", filtered)
    end
  end

  def filtered_server(_), do: invalid()

  def logging_event(%Model{type: "Event", data: raw}), do: logging_event(raw)

  def logging_event(raw) when is_map(raw) do
    with {:ok, event} <- project("Event", raw),
         {:ok, record} <- log_record(event.data) do
      Model.decode("EventLogRecord", Map.put(record, "Time", event.data["timestamp"]))
    end
  end

  def logging_event(_), do: invalid()

  defp filter_config(nil), do: nil

  defp filter_config(config) do
    Map.new(config, fn {key, value} ->
      segment = key |> String.split(".") |> List.last()
      sensitive = Enum.any?(~w(key cert password secret token), &String.ends_with?(segment, &1))
      {key, if(value != "" and sensitive, do: "SENSITIVE", else: value)}
    end)
  end

  defp log_record(%{"type" => type, "metadata" => metadata})
       when type in ["logging", "network-acl"] and is_map(metadata) do
    with {:ok, entry} <- project("EventLogging", metadata) do
      {:ok,
       %{
         "Lvl" => entry.data["level"],
         "Msg" => entry.data["message"],
         "Ctx" => context(entry.data["context"])
       }}
    end
  end

  defp log_record(%{"type" => "lifecycle", "metadata" => metadata}) when is_map(metadata) do
    with {:ok, entry} <- project("EventLifecycle", metadata) do
      data = entry.data
      message = "Action: #{data["action"]}, Source: #{data["source"]}"

      {:ok,
       %{
         "Lvl" => "info",
         "Msg" => message <> requestor(data["requestor"]),
         "Ctx" => context(data["context"])
       }}
    end
  end

  defp log_record(%{"type" => "operation", "metadata" => metadata}) when is_map(metadata) do
    with {:ok, entry} <- project("Operation", metadata) do
      data = entry.data

      pairs = [
        {"CreatedAt", "created_at"},
        {"UpdatedAt", "updated_at"},
        {"Status", "status"},
        {"StatusCode", "status_code"},
        {"Resources", "resources"},
        {"Metadata", "metadata"},
        {"MayCancel", "may_cancel"},
        {"Err", "err"},
        {"Location", "location"}
      ]

      {:ok,
       %{
         "Lvl" => "info",
         "Msg" =>
           "ID: #{data["id"]}, Class: #{data["class"]}, Description: #{data["description"]}",
         "Ctx" => Enum.flat_map(pairs, fn {key, field} -> [key, data[field]] end)
       }}
    end
  end

  defp log_record(%{"type" => type})
       when type not in ["logging", "network-acl", "lifecycle", "operation"],
       do:
         {:error,
          %Error{kind: :unsupported_event_type, message: "Not supported event type: " <> type}}

  defp log_record(_), do: invalid()
  defp requestor(nil), do: ""

  defp requestor(data),
    do: ", Requestor: #{data["protocol"]}/#{data["username"]} (#{data["address"]})"

  defp context(nil), do: []
  defp context(data), do: Enum.flat_map(Enum.sort(data), fn {key, value} -> [key, value] end)
  defp project(type, data), do: Response.metadata_as_model(%Response{metadata: data}, type)
  defp invalid, do: {:error, %Error{kind: :invalid_metadata}}
end
