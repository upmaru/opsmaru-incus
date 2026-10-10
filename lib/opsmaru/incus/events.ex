defmodule Opsmaru.Incus.Events do
  @moduledoc "Native bounded event subscription. Overflow requires authoritative reconciliation."
  alias Opsmaru.Incus.{Error, Model, WebSocket}

  def subscribe(client, opts \\ []) do
    types = opts[:types] || []

    with :ok <- all_projects(client, opts[:all_projects]),
         true <-
           is_list(types) and length(types) <= 32 and
             Enum.all?(types, &(is_binary(&1) and byte_size(&1) in 1..128)) do
      query = []
      query = if opts[:all_projects], do: [{"all-projects", "true"} | query], else: query
      query = if types != [], do: [{"type", Enum.join(types, ",")} | query], else: query

      WebSocket.open(
        client,
        "/1.0/events" <> if(query == [], do: "", else: "?" <> URI.encode_query(query))
      )
    else
      {:error, error} -> {:error, error}
      _ -> {:error, %Error{kind: :invalid_event_types}}
    end
  end

  def next(channel, timeout \\ 5_000) do
    with {:ok, {type, payload}} when type in [:text, :binary] <- WebSocket.recv(channel, timeout),
         {:ok, event} <- Jason.decode(payload),
         {:ok, model} <- Model.decode("Event", event) do
      {:ok, model}
    else
      :eof ->
        :eof

      {:error, %Error{} = error} ->
        {:error, error}

      _ ->
        WebSocket.close(channel)
        {:error, %Error{kind: :invalid_event}}
    end
  end

  def close(channel), do: WebSocket.close(channel)
  defp all_projects(_, _), do: :ok
end
