defmodule Opsmaru.Incus.Discovery do
  @moduledoc "Native connection/discovery helpers. Advertised addresses are metadata and are never followed."
  alias Opsmaru.Incus.{Context, Error, Model}
  defstruct [:certificate, :protocol, :url, :socket_path, :project, :target, addresses: []]

  def connection_info(client) do
    with :ok <- authorize(client),
         {:ok, environment} <- environment(client) do
      connection = client.connection

      url =
        if connection.transport == :unix,
          do: "http://unix.socket",
          else: URI.to_string(connection.address)

      addresses = if connection.transport == :https, do: [url], else: []

      advertised =
        (environment["addresses"] || [])
        |> Enum.reject(&String.starts_with?(&1, ":"))
        |> Enum.map(&("https://" <> &1))

      {:ok,
       %__MODULE__{
         certificate: environment["certificate"] || "",
         protocol: "incus",
         url: url,
         socket_path: if(connection.transport == :unix, do: connection.address, else: ""),
         project: connection.project || "default",
         target: connection.member || environment["server_name"] || "",
         addresses: Enum.uniq(addresses ++ advertised)
       }}
    end
  end

  def clustered?(client) do
    with :ok <- authorize(client),
         {:ok, environment} <- environment(client),
         do: {:ok, environment["server_clustered"] == true}
  end

  def agent?(client) do
    with :ok <- authorize(client),
         {:ok, environment} <- environment(client),
         do: {:ok, environment["server"] == "incus-agent"}
  end

  @doc "Return an immutable client asking Incus to require backend authentication on every request."
  def require_authenticated(client, flag \\ true) do
    with :ok <- authorize(client) do
      if is_boolean(flag),
        do: {:ok, %{client | connection: %{client.connection | require_authenticated: flag}}},
        else: {:error, %Error{kind: :invalid_arguments}}
    end
  end

  defp authorize(client) do
    case Context.authorize(client.context, client.connection) do
      :ok -> :ok
      {:error, kind} -> {:error, %Error{kind: kind}}
    end
  end

  defp environment(client) do
    data = client.server.environment || %{}

    case Model.decode("ServerEnvironment", data) do
      {:ok, %Model{data: data}} when is_map(data) ->
        addresses = data["addresses"] || []

        if length(addresses) <= 1024 and Enum.all?(addresses, &(byte_size(&1) <= 1024)),
          do: {:ok, data},
          else: {:error, %Error{kind: :response_limit}}

      _ ->
        {:error, %Error{kind: :invalid_server}}
    end
  end
end

defimpl Inspect, for: Opsmaru.Incus.Discovery do
  def inspect(_, _), do: "#Opsmaru.Incus.Discovery<connection metadata redacted>"
end
