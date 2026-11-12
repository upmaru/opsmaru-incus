defmodule Opsmaru.Incus.FileHeaders do
  @moduledoc """
  Pure bounded counterpart of native ParseFileHeaders. Header names are
  case-insensitive and the first duplicate wins, as with http.Header.Get.
  Native malformed numeric fields become -1; unknown type/write values remain
  caller data. Parsing does not authorize a file operation or contact a backend.
  """
  alias Opsmaru.Incus.Error

  @minimum -9_223_372_036_854_775_808
  @maximum 9_223_372_036_854_775_807

  def parse(headers) when is_map(headers), do: parse(Map.to_list(headers))

  def parse(headers) when is_list(headers) and length(headers) <= 128 do
    if valid_headers?(headers) do
      values =
        Enum.reduce(headers, %{}, fn {key, value}, acc ->
          Map.put_new(acc, String.downcase(key), value)
        end)

      {:ok,
       %{
         uid: ownership(values["x-incus-uid"]),
         gid: ownership(values["x-incus-gid"]),
         mode: mode(values["x-incus-mode"]),
         type: default(values["x-incus-type"], "file"),
         write_mode: default(values["x-incus-write"], "overwrite")
       }}
    else
      invalid()
    end
  end

  def parse(_), do: invalid()

  defp valid_headers?(headers) do
    Enum.all?(headers, fn
      {key, value} when is_binary(key) and is_binary(value) ->
        String.valid?(key) and String.valid?(value) and byte_size(key) <= 1024 and
          byte_size(value) <= 16_384

      _ ->
        false
    end) and
      Enum.reduce(headers, 0, fn {key, value}, sum -> sum + byte_size(key) + byte_size(value) end) <=
        16_384
  end

  defp decimal(value) when is_binary(value) do
    if Regex.match?(~r/\A[+-]?[0-9]+\z/, value) do
      case Integer.parse(value) do
        {number, ""} when number >= @minimum and number <= @maximum -> {:ok, number}
        _ -> :invalid
      end
    else
      :invalid
    end
  end

  defp decimal(_), do: :invalid

  defp ownership(value) do
    case decimal(value) do
      {:ok, number} -> number
      :invalid -> -1
    end
  end

  defp mode(value) do
    case decimal(value) do
      {:ok, parsed} -> native_mode(value, parsed)
      :invalid -> -1
    end
  end

  defp native_mode(value, parsed) do
    unsigned = String.trim_leading(String.trim_leading(value, "+"), "-")
    radix = if String.starts_with?(unsigned, "0") and byte_size(unsigned) > 1, do: 8, else: 10

    case Integer.parse(unsigned, radix) do
      {number, ""} ->
        number = if String.starts_with?(value, "-"), do: -number, else: number

        if number >= @minimum and number <= @maximum,
          do: Bitwise.band(number, 0o777),
          else: parsed

      _ ->
        parsed
    end
  end

  defp default(value, fallback) when value in [nil, ""], do: fallback
  defp default(value, _), do: value
  defp invalid, do: {:error, %Error{kind: :invalid_file_headers}}
end
