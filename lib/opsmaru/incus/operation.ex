defmodule Opsmaru.Incus.Operation do
  @moduledoc """
  Native accepted operation bound to the originating backend and host identity.
  Poll/wait keep native identity and metadata. Local timeout/stream close never
  imply cancellation. Cancellation first checks authoritative `may_cancel` and
  issues at most one native DELETE. No application task/persistence is created.
  """
  alias Opsmaru.Incus
  alias Opsmaru.Incus.{Error, Model, RequestContext, Response, WebSocket}
  @enforce_keys [:client, :url]
  defstruct [:client, :url, :response]

  @doc "Explicit native RawOperation request, retaining ETag and accepted identity without waiting."
  def raw(client, method, path, opts \\ []) do
    with {:ok, response} <- Incus.raw_query(client, method, path, opts),
         do: from_response(client, response)
  end

  def from_response(client, %Response{} = response) do
    if response.type == "async" and response.connection == client.connection and
         response.identity === client.context.identity and valid_url?(response.operation) do
      {:ok, %__MODULE__{client: client, url: response.operation, response: response}}
    else
      {:error,
       %Error{kind: :invalid_operation_binding, response: response, operation: response.operation}}
    end
  end

  def poll(operation) do
    case Incus.raw_query(operation.client, "GET", operation.url) do
      {:ok, response} ->
        case Model.decode("Operation", response.metadata) do
          {:ok, metadata} ->
            {:ok, %{operation | response: %{response | metadata: metadata}}}

          _ ->
            {:error,
             %Error{kind: :invalid_operation, response: response, operation: operation.url}}
        end

      {:error, %Error{} = error} ->
        {:error,
         %{error | operation: operation.url, response: error.response || operation.response}}
    end
  end

  @doc "Return the current immutable native snapshot without querying Incus."
  def get(operation), do: Model.decode("Operation", data(operation))

  @doc "Refresh the native snapshot on its originating client, retaining identity and ETag."
  def refresh(operation), do: poll(operation)

  @doc "Bound a local wait to an explicit request context; cancellation never sends a backend DELETE."
  def wait_with_context(operation, request_context, opts \\ []),
    do: wait(%{operation | client: Incus.with_context(operation.client, request_context)}, opts)

  def wait(operation, opts \\ []) do
    if Keyword.keyword?(opts) and Keyword.keys(opts) -- [:timeout, :poll_interval] == [] and
         length(opts) == length(Enum.uniq(Keyword.keys(opts))),
       do: wait_options(operation, opts),
       else: {:error, %Error{kind: :invalid_deadline, operation: operation.url}}
  end

  defp wait_options(operation, opts) do
    timeout = opts[:timeout] || operation.client.connection.timeout
    interval = opts[:poll_interval] || 50

    if is_integer(timeout) and timeout in 1..3_600_000 and is_integer(interval) and
         interval in 1..60_000 do
      wait_until(
        operation,
        RequestContext.deadline(operation.client.connection.request_context, now() + timeout),
        interval
      )
    else
      {:error, %Error{kind: :invalid_deadline, operation: operation.url}}
    end
  end

  defp wait_until(operation, deadline, interval) do
    remaining = max(0, deadline - now())

    if remaining == 0 do
      {:error, %Error{kind: :deadline, response: operation.response, operation: operation.url}}
    else
      client = %{
        operation.client
        | connection: %{
            operation.client.connection
            | timeout: min(operation.client.connection.timeout, remaining)
          }
      }

      case poll(%{operation | client: client}) do
        {:ok, current} ->
          current = %{current | client: operation.client}

          if completed?(current) do
            completion_result(current)
          else
            sleep_until(
              min(now() + interval, deadline),
              operation.client.connection.request_context
            )

            wait_until(current, deadline, interval)
          end

        {:error, error} ->
          {:error, %{error | operation: operation.url}}
      end
    end
  end

  defp sleep_until(deadline, nil), do: Process.sleep(max(0, deadline - now()))

  defp sleep_until(deadline, context) do
    remaining = deadline - now()

    if remaining > 0 and RequestContext.status(context) == :active do
      Process.sleep(min(20, remaining))
      sleep_until(deadline, context)
    end
  end

  defp completion_result(current) do
    if successful?(current),
      do: {:ok, current},
      else:
        {:error,
         %Error{kind: :operation_failed, response: current.response, operation: current.url}}
  end

  def cancel(operation) do
    with {:ok, current} <- poll(operation) do
      cond do
        completed?(current) ->
          {:ok, current}

        data(current)["may_cancel"] == true ->
          case Incus.raw_query(current.client, "DELETE", current.url) do
            # cancellation requested; completion remains authoritative.
            {:ok, response} -> {:ok, %{current | response: response}}
            {:error, error} -> {:error, %{error | operation: current.url}}
          end

        true ->
          {:error,
           %Error{
             kind: :cancellation_unsupported,
             response: current.response,
             operation: current.url
           }}
      end
    end
  end

  def websocket(operation, secret) when is_binary(secret) and byte_size(secret) in 1..4096,
    do:
      WebSocket.open(
        operation.client,
        operation.url <> "/websocket?" <> URI.encode_query(secret: secret)
      )

  def completed?(operation),
    do: is_integer(data(operation)["status_code"]) and data(operation)["status_code"] >= 200

  def successful?(operation), do: data(operation)["status_code"] == 200
  def data(%{response: %{metadata: %Model{data: data}}}) when is_map(data), do: data
  def data(%{response: %{metadata: data}}) when is_map(data), do: data
  def data(_), do: %{}

  defp valid_url?(url) when is_binary(url) do
    uri = URI.parse(url)

    String.starts_with?(url, "/1.0/operations/") and is_nil(uri.host) and is_nil(uri.query) and
      is_nil(uri.fragment) and length(String.split(url, "/")) == 4 and
      List.last(String.split(url, "/")) != ""
  end

  defp valid_url?(_), do: false
  defp now, do: System.monotonic_time(:millisecond)
end

defimpl Inspect, for: Opsmaru.Incus.Operation do
  def inspect(_, _), do: "#Opsmaru.Incus.Operation<bound native handle redacted>"
end
