defmodule Opsmaru.Incus.HTTP.Response do
  @moduledoc "Bounded raw native HTTP response. Payload and origin are privileged caller values."
  defstruct [:status, :headers, :body, :connection, :identity, trailers: []]

  @doc "The first native header value, like net/http Header.Get; duplicates remain in headers."
  def header(response, name), do: value(response.headers, name)
  def trailer(response, name), do: value(response.trailers, name)

  defp value(headers, name),
    do:
      Enum.find_value(headers, fn {key, value} -> if key == String.downcase(name), do: value end)
end

defimpl Inspect, for: Opsmaru.Incus.HTTP.Response do
  def inspect(response, _),
    do: "#Opsmaru.Incus.HTTP.Response<HTTP #{response.status} payload redacted>"
end
