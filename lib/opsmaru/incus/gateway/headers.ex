defmodule Opsmaru.Incus.Gateway.Headers do
  @moduledoc """
  Request/response header handling for the native relay.

  Hop-by-hop fields (RFC 9110 section 7.6.1, plus any named by `connection`)
  are removed in both directions. Caller credentials and proxy identity fields
  (`authorization`, `proxy-authorization`, `cookie`, `forwarded`,
  `x-forwarded-*`, `x-real-ip`) are never forwarded to the backend; the backend
  only sees the gateway's own connection identity. `host` is set by the
  backend connection. Every other end-to-end field, including duplicates and
  `x-incus-*` fields, is forwarded unchanged.
  """

  alias Opsmaru.Incus.Gateway.Failure

  @hop_by_hop ~w(connection keep-alive proxy-connection te trailer transfer-encoding upgrade)
  @caller_only ~w(host authorization proxy-authorization cookie forwarded x-real-ip expect content-length)

  @doc """
  Filter caller headers for the backend and choose the request body framing.

  Returns `{:ok, headers, body}` where body is `:none`, `{:length, n}` or
  `:chunked`, or `{:error, failure}` before any backend contact.
  """
  def request(headers, max_header_bytes, max_request_bytes, chunked? \\ false) do
    with :ok <- header_budget(headers, max_header_bytes),
         {:ok, body} <- request_body(headers, max_request_bytes, chunked?) do
      forwarded =
        headers
        |> drop(connection_tokens(headers) ++ @hop_by_hop ++ @caller_only)
        |> Enum.reject(fn {name, _} -> String.starts_with?(name, "x-forwarded-") end)

      forwarded =
        case body do
          {:length, length} -> forwarded ++ [{"content-length", Integer.to_string(length)}]
          :none -> zero_length(headers, forwarded)
          :chunked -> forwarded
        end

      {:ok, forwarded, body}
    end
  end

  defp header_budget(headers, maximum) do
    bytes =
      Enum.reduce(headers, 0, fn {name, value}, sum ->
        sum + byte_size(name) + byte_size(value) + 4
      end)

    if bytes <= maximum,
      do: :ok,
      else: {:error, Failure.new(431, "Request header fields are too large", :not_sent)}
  end

  # `chunked?` is the server adapter's own report of a body without a length;
  # Cowboy removes `transfer-encoding` once it decodes chunked framing.
  defp request_body(headers, maximum, chunked?) do
    lengths = for {"content-length", value} <- headers, do: value
    encodings = for {"transfer-encoding", value} <- headers, do: value

    cond do
      lengths != [] and encodings != [] ->
        {:error, Failure.new(400, "Ambiguous request framing", :not_sent)}

      encodings != [] or (chunked? and lengths == []) ->
        {:ok, :chunked}

      lengths == [] ->
        {:ok, :none}

      true ->
        content_length(lengths, maximum)
    end
  end

  # Repeated identical values are one length (RFC 9110 section 8.6).
  defp content_length(lengths, maximum) do
    values =
      lengths
      |> Enum.flat_map(&String.split(&1, ","))
      |> Enum.map(&String.trim/1)
      |> Enum.uniq()

    case values do
      [value] -> parse_length(Integer.parse(value), maximum)
      _ -> {:error, Failure.new(400, "Ambiguous request framing", :not_sent)}
    end
  end

  defp parse_length({length, ""}, maximum) when length > maximum,
    do: {:error, Failure.new(413, "Request body exceeds the gateway limit", :not_sent)}

  defp parse_length({0, ""}, _), do: {:ok, :none}
  defp parse_length({length, ""}, _) when length > 0, do: {:ok, {:length, length}}
  defp parse_length(_, _), do: {:error, Failure.new(400, "Ambiguous request framing", :not_sent)}

  defp zero_length(original, forwarded) do
    if List.keymember?(original, "content-length", 0),
      do: forwarded ++ [{"content-length", "0"}],
      else: forwarded
  end

  @doc """
  Validate and filter backend response headers (or trailers) for the caller.
  Returns `{:ok, headers}` or `:error` for a field that could inject or
  smuggle a response.
  """
  def response(headers) do
    if Enum.all?(headers, &safe?/1),
      do: {:ok, drop(headers, connection_tokens(headers) ++ @hop_by_hop)},
      else: :error
  end

  @doc "Trailer fields that must never appear after a body."
  def trailers(headers) do
    with {:ok, headers} <- response(headers) do
      {:ok,
       drop(headers, ~w(content-length content-type content-encoding host set-cookie location))}
    end
  end

  defp safe?({name, value}) do
    is_binary(name) and is_binary(value) and name != "" and
      Regex.match?(~r/\A[!#$%&'*+\-.^_`|~0-9a-z]+\z/, name) and
      not Regex.match?(~r/[\x00-\x08\x0a-\x1f\x7f]/, value)
  end

  defp connection_tokens(headers) do
    for {"connection", value} <- headers,
        token <- String.split(value, ","),
        token = token |> String.trim() |> String.downcase(),
        token != "",
        do: token
  end

  defp drop(headers, names), do: Enum.reject(headers, fn {name, _} -> name in names end)
end
