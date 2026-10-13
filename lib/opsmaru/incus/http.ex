defmodule Opsmaru.Incus.HTTP do
  @moduledoc """
  Portable GetHTTPClient/DoHTTP slice over an explicitly bound native backend or verified image origin.

  `client/1` returns an immutable HTTP handle without starting a pool or process.
  `request/4` accepts a native relative API path and optional binary body/headers,
  returning raw HTTP status, headers and binary body under the connection's
  request deadline and byte limits. HTTP status alone is not native operation
  completion. Redirects and 305 responses are returned without replay; streaming
  native transfers use the separate Transfer/Files/Images interfaces.
  """
  alias Opsmaru.{Context, Incus}
  alias Opsmaru.Incus.{Error, OCI, SimpleStreams, Transport}
  @enforce_keys [:client]
  defstruct [:client]

  def client(%Incus{} = client), do: {:ok, %__MODULE__{client: client}}
  def client(%SimpleStreams{} = client), do: {:ok, %__MODULE__{client: client}}

  def client(%OCI{connection: %{transport: :https}} = client),
    do: {:ok, %__MODULE__{client: client}}

  def client(%OCI{}), do: {:error, %Error{kind: :invalid_origin}}

  def request(%__MODULE__{client: client}, method, path, opts \\ []) do
    with :ok <- options(method, opts, client.connection.max_request_bytes),
         :ok <- Context.authorize(client.context, client.connection),
         {:ok, path} <- request_path(client, path),
         {:ok, response} <-
           perform(
             client.connection,
             method,
             path,
             Keyword.get(opts, :headers, []),
             opts[:body]
           ) do
      {:ok,
       %Opsmaru.Incus.HTTP.Response{
         status: response.status,
         headers: response.raw_headers || [],
         trailers: response.trailers,
         body: response.body,
         connection: client.connection,
         identity: client.context.identity
       }}
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, kind} -> {:error, %Error{kind: kind}}
    end
  end

  defp request_path(%Incus{} = client, path), do: Incus.request_path(client.connection, path)

  defp request_path(%module{}, path)
       when module in [OCI, SimpleStreams] and is_binary(path) and byte_size(path) <= 16_384 do
    uri = URI.parse(path)

    with true <-
           String.valid?(path) and String.starts_with?(path, "/") and
             not String.starts_with?(path, "//") and
             Enum.all?([uri.scheme, uri.host, uri.fragment], &is_nil/1) and
             not String.contains?(URI.decode(path), ["\r", "\n", <<0>>]),
         false <- Regex.match?(~r/%(?![0-9a-fA-F]{2})/, path),
         {:ok, clean_path} <- SimpleStreams.path(uri.path) do
      {:ok, clean_path <> if(is_nil(uri.query), do: "", else: "?" <> uri.query)}
    else
      _ -> {:error, :invalid_path}
    end
  rescue
    _ -> {:error, :invalid_path}
  end

  defp request_path(%module{}, _) when module in [OCI, SimpleStreams], do: {:error, :invalid_path}

  defp perform(connection, method, path, headers, body) do
    case Transport.request(connection, method, path, headers, body) do
      {:error, kind} when is_atom(kind) ->
        {:error, %Error{kind: if(method in ["GET", "HEAD"], do: kind, else: :uncertain)}}

      result ->
        result
    end
  end

  defp options(method, opts, maximum) do
    if method in ~w(GET HEAD POST PUT PATCH DELETE OPTIONS) and Keyword.keyword?(opts) and
         length(opts) <= 2 and Keyword.keys(opts) -- [:body, :headers] == [] and
         length(opts) == length(Enum.uniq(Keyword.keys(opts))) and
         (is_nil(opts[:body]) or (is_binary(opts[:body]) and byte_size(opts[:body]) <= maximum)) and
         valid_headers?(Keyword.get(opts, :headers, [])),
       do: :ok,
       else: {:error, :invalid_http_request}
  end

  @doc false
  def valid_headers?(headers) when is_list(headers) and length(headers) <= 128,
    do:
      Enum.all?(headers, fn
        {name, value} when is_binary(name) and is_binary(value) ->
          Regex.match?(~r/\A[a-z0-9-]+\z/, name) and byte_size(name) <= 256 and
            byte_size(value) <= 16_384 and not String.contains?(value, ["\r", "\n", <<0>>]) and
            name not in ~w(host connection content-length transfer-encoding authorization x-incus-authenticated)

        _ ->
          false
      end)

  def valid_headers?(_), do: false
end

defimpl Inspect, for: Opsmaru.Incus.HTTP do
  def inspect(_, _), do: "#Opsmaru.Incus.HTTP<immutable bound handle redacted>"
end
