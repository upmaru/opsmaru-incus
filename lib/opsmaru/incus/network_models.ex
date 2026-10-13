defmodule Opsmaru.Incus.NetworkModels do
  @moduledoc """
  Explicit native network Normalise helpers; ordinary Model.decode is lossless.

  Accepts a supported native Model, casts its known fields with native typed
  JSON defaults and applies the pinned helper's string/list/IP normalization.
  Unknown fields are discarded only by this explicit typed projection. No
  network call or implicit normalization of mutation bodies occurs. Input and
  output are bounded to 1 MiB; supported types are returned by `types/0`.
  """
  alias Opsmaru.Incus.{Error, Model, NativeInput}
  @limit 1_048_576
  @types ~w(NetworkACLRule NetworkAddressSet NetworkForwardPort NetworkForwardPut NetworkForwardsPost NetworkLoadBalancerBackend NetworkLoadBalancerPort NetworkLoadBalancerPut)
  def types, do: @types

  def normalise(%Model{type: type, data: data}) when type in @types and is_map(data) do
    with {:ok, encoded} <- Jason.encode(data),
         true <- byte_size(encoded) <= @limit,
         {:ok, data} <- NativeInput.cast(type, data),
         data <- fields(type, data),
         {:ok, encoded} <- Jason.encode(data),
         true <- byte_size(encoded) <= @limit,
         {:ok, result} <- Model.decode(type, data) do
      {:ok, result}
    else
      _ -> {:error, %Error{kind: :invalid_network_model}}
    end
  rescue
    _ -> {:error, %Error{kind: :invalid_network_model}}
  end

  def normalise(_), do: {:error, %Error{kind: :unsupported_model_helper}}

  defp fields("NetworkACLRule", data) do
    data
    |> transform(~w(action protocol icmp_type icmp_code description state), &trim/1)
    |> transform(~w(source destination source_port destination_port), &list/1)
    |> Map.reject(fn {key, value} -> key not in ~w(action state) and value == "" end)
  end

  defp fields("NetworkAddressSet", data) do
    data
    |> Map.update!("name", &trim/1)
    |> Map.update!("addresses", &Enum.map(&1 || [], fn address -> trim(address) end))
    |> Map.update("config", nil, fn
      nil -> nil
      config -> Map.new(config, fn {key, value} -> {trim(key), trim(value)} end)
    end)
    |> Map.reject(fn {key, value} -> key == "config" and value in [nil, %{}] end)
  end

  defp fields("NetworkForwardPort", data) do
    data
    |> transform(~w(description protocol target_address), &trim/1)
    |> transform(~w(listen_port target_port), &list/1)
    |> Map.update!("target_address", &ip/1)
  end

  defp fields("NetworkForwardPut", data) do
    data
    |> Map.update!("description", &trim/1)
    |> Map.update!("config", fn
      nil ->
        nil

      config ->
        if Map.has_key?(config, "target_address"),
          do: Map.update!(config, "target_address", &ip/1),
          else: config
    end)
    |> children("ports", "NetworkForwardPort")
  end

  defp fields("NetworkForwardsPost", data),
    do: data |> Map.update!("listen_address", &ip/1) |> fields_as("NetworkForwardPut")

  defp fields("NetworkLoadBalancerBackend", data) do
    data
    |> transform(~w(description target_address), &trim/1)
    |> Map.update!("target_address", &ip/1)
    |> Map.update!("target_port", &list/1)
  end

  defp fields("NetworkLoadBalancerPort", data),
    do:
      data |> transform(~w(description protocol), &trim/1) |> Map.update!("listen_port", &list/1)

  defp fields("NetworkLoadBalancerPut", data),
    do:
      data
      |> Map.update!("description", &trim/1)
      |> children("backends", "NetworkLoadBalancerBackend")
      |> children("ports", "NetworkLoadBalancerPort")

  defp fields_as(data, type), do: fields(type, data)

  defp children(data, key, type),
    do:
      Map.update!(data, key, fn
        nil -> nil
        children -> Enum.map(children, &fields(type, &1))
      end)

  defp transform(data, keys, callback),
    do: Enum.reduce(keys, data, &Map.update(&2, &1, callback.(""), callback))

  # strings.TrimSpace's Unicode White_Space set deliberately excludes FEFF
  # and zero-width space. Explicit spelling keeps OTP/Unicode drift visible.
  @space "[\\x{0009}-\\x{000D}\\x{0020}\\x{0085}\\x{00A0}\\x{1680}\\x{2000}-\\x{200A}\\x{2028}\\x{2029}\\x{202F}\\x{205F}\\x{3000}]"
  @trim Regex.compile!("\\A#{@space}+|#{@space}+\\z", "u")
  defp trim(value), do: Regex.replace(@trim, value, "")

  defp list(value), do: value |> String.split(",") |> Enum.map_join(",", &trim/1)

  defp ip(value) do
    valid_chars = Regex.match?(~r/\A[0-9a-fA-F:.]+\z/, value)
    dotted = List.last(String.split(value, ":"))
    valid_dotted = not String.contains?(value, ".") or ipv4?(dotted)

    if valid_chars and valid_dotted and (String.contains?(value, ":") or ipv4?(value)) do
      case :inet.parse_address(String.to_charlist(value)) do
        {:ok, address} -> address_text(address)
        _ -> value
      end
    else
      value
    end
  end

  defp ipv4?(value) do
    parts = String.split(value, ".")

    length(parts) == 4 and
      Enum.all?(parts, fn part ->
        Regex.match?(~r/\A(?:0|[1-9][0-9]{0,2})\z/, part) and String.to_integer(part) <= 255
      end)
  end

  defp address_text({a, b, c, d}), do: Enum.join([a, b, c, d], ".")

  defp address_text({0, 0, 0, 0, 0, 65_535, a, b}),
    do: address_text({div(a, 256), rem(a, 256), div(b, 256), rem(b, 256)})

  defp address_text(address) do
    parts = Tuple.to_list(address)
    {first, count} = zero_run(parts)
    hex = Enum.map(parts, &Integer.to_string(&1, 16))

    if count < 2 do
      Enum.join(hex, ":")
    else
      Enum.join(Enum.take(hex, first), ":") <>
        "::" <> Enum.join(Enum.drop(hex, first + count), ":")
    end
    |> String.downcase()
  end

  defp zero_run(parts) do
    parts
    |> Enum.with_index()
    |> Enum.reduce({{0, 0}, {0, 0}}, fn {value, index}, {best, {start, count}} ->
      run = if value == 0, do: {if(count == 0, do: index, else: start), count + 1}, else: {0, 0}
      best = if elem(run, 1) > elem(best, 1), do: run, else: best
      {best, run}
    end)
    |> elem(0)
  end
end
