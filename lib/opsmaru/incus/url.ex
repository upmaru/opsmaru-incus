defmodule Opsmaru.Incus.URL do
  @moduledoc """
  Pure, immutable counterpart of the pinned API URL builder.

  Setters return `{:ok, url}`. `path/2` replaces the entire path; query setters
  append values, including duplicates. `render/1` explicitly exposes the native
  URL string. Inspection is redacted. Values are bounded to 16 KiB rendered,
  4 KiB per component, 64 path parts and 128 query pairs. This helper does not
  select, verify or contact a backend; use explicit Connection values for I/O.
  """
  alias Opsmaru.Incus.Error
  defstruct scheme: "", host: "", parts: [], query: [], fragment: ""

  def new, do: %__MODULE__{}
  def scheme(url, value), do: set(url, :scheme, value)
  def host(url, value), do: set(url, :host, value)
  def fragment(url, value), do: set(url, :fragment, value)

  def path(%__MODULE__{} = url, parts) when is_list(parts) and length(parts) <= 64,
    do: checked(%{url | parts: parts})

  def path(_, _), do: invalid()

  def project(url, value), do: selection(url, "project", value, ["", "default"])
  def target(url, value), do: selection(url, "target", value, ["", "none"])

  def with_query(%__MODULE__{query: query} = url, key, value)
      when is_list(query) and length(query) < 128,
      do: checked(%{url | query: query ++ [{key, value}]})

  def with_query(_, _, _), do: invalid()

  def render(%__MODULE__{} = url) do
    if valid?(url) do
      value = native_string(url)
      if byte_size(value) <= 16_384, do: {:ok, value}, else: invalid()
    else
      invalid()
    end
  end

  def render(_), do: invalid()

  defp set(%__MODULE__{} = url, key, value), do: checked(Map.put(url, key, value))
  defp set(_, _, _), do: invalid()

  defp selection(url, key, value, suppressed) do
    cond do
      not component?(value) -> invalid()
      value in suppressed -> checked(url)
      true -> with_query(url, key, value)
    end
  end

  defp checked(url) do
    case render(url) do
      {:ok, _} -> {:ok, url}
      error -> error
    end
  end

  defp valid?(url) do
    component?(url.scheme) and component?(url.host) and component?(url.fragment) and
      bounded_list?(url.parts, 64) and Enum.all?(url.parts, &component?/1) and
      bounded_list?(url.query, 128) and
      Enum.all?(url.query, fn
        {key, value} -> component?(key) and component?(value)
        _ -> false
      end)
  end

  defp bounded_list?([], _), do: true

  defp bounded_list?([_ | rest], remaining) when remaining > 0,
    do: bounded_list?(rest, remaining - 1)

  defp bounded_list?(_, _), do: false

  defp component?(value),
    do: is_binary(value) and byte_size(value) <= 4096 and String.valid?(value)

  defp native_string(url) do
    scheme = if url.scheme == "", do: "", else: url.scheme <> ":"
    path = Enum.map_join(url.parts, "", &("/" <> escape(&1, ~c"$&+:=@")))

    authority =
      if (url.scheme != "" or url.host != "") and (url.host != "" or path != ""),
        do: "//" <> escape(url.host, ~c"!$&'()*+,;=:[]<>\""),
        else: ""

    query =
      url.query
      |> Enum.with_index()
      |> Enum.sort_by(fn {{key, _}, index} -> {key, index} end)
      |> Enum.map_join("&", fn {{key, value}, _} ->
        query_escape(key) <> "=" <> query_escape(value)
      end)

    scheme <>
      authority <>
      path <>
      if(query == "", do: "", else: "?" <> query) <>
      if(url.fragment == "", do: "", else: "#" <> escape(url.fragment, ~c"$&+,/:;=?@!()*"))
  end

  defp query_escape(value), do: value |> escape([]) |> String.replace("%20", "+")
  defp escape(value, allowed), do: URI.encode(value, &(URI.char_unreserved?(&1) or &1 in allowed))
  defp invalid, do: {:error, %Error{kind: :invalid_native_url}}
end

defimpl Inspect, for: Opsmaru.Incus.URL do
  def inspect(_, _), do: "#Opsmaru.Incus.URL<passive value redacted>"
end
