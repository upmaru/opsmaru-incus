defmodule Opsmaru.Incus.Gateway.Identity do
  @moduledoc """
  Bounded public identity mediation. The host supplies explicitly verified
  backend metadata bound to the fixed connection. No discovery probe occurs.
  The conservative extension allowlist depends on the available optional
  protocol adapters. The host must approve only capabilities of protocols it
  actually mounts and of its verified backend. Migration and token issuance
  remain excluded until their independent implementation and evidence exist.
  """

  alias Opsmaru.Incus.Gateway.{Failure, Policy}

  @extensions ~w(certificate_update instances)
  @websocket_extensions ~w(console)
  @raw_extensions ~w(instance_nbd custom_volume_sftp storage_volume_nbd)

  def load(gateway, request) do
    result =
      Policy.callback(
        fn ->
          with {:ok, identity} <- gateway.host.identity(request, gateway.host_config),
               true <- valid?(identity, gateway) do
            {:ok,
             Map.update!(
               identity,
               :api_extensions,
               &Enum.filter(&1, fn x -> x in supported_extensions() end)
             )}
          end
        end,
        gateway.callback_timeout
      )

    case result do
      {:ok, {:ok, identity}} -> {:ok, identity}
      _ -> {:error, Failure.new(503, "Gateway identity is unavailable", :not_sent)}
    end
  end

  @doc false
  def supported_extensions do
    websocket =
      if Code.ensure_loaded?(Opsmaru.Incus.Gateway.WebSocket), do: @websocket_extensions, else: []

    raw =
      if Code.ensure_loaded?(Opsmaru.Incus.Gateway.CowboyHandler), do: @raw_extensions, else: []

    @extensions ++ websocket ++ raw
  end

  defp valid?(
         %{
           origin: origin,
           addresses: addresses,
           certificate: certificate,
           connection: connection,
           api_extensions: extensions
         } = identity,
         gateway
       ) do
    :erlang.external_size(Map.delete(identity, :connection)) <= gateway.max_identity_bytes and
      connection == gateway.connection and origin?(origin) and is_list(addresses) and
      Enum.all?(addresses, &address?/1) and is_binary(certificate) and certificate?(certificate) and
      is_list(extensions) and Enum.all?(extensions, &is_binary/1)
  end

  defp valid?(_, _), do: false

  defp origin?(origin) when is_binary(origin) do
    uri = URI.parse(origin)

    uri.scheme == "https" and public_host?(uri.host) and uri.userinfo == nil and
      uri.path in [nil, ""] and uri.query == nil and uri.fragment == nil and port?(uri.port)
  end

  defp origin?(_), do: false

  defp address?(address) when is_binary(address), do: origin?("https://" <> address)
  defp address?(_), do: false
  defp port?(port), do: is_integer(port) and port in 1..65_535

  # No DNS lookups. Hosts remain responsible for public DNS; literal private,
  # loopback, link-local and unspecified addresses and socket names are refused.
  defp public_host?(host) when is_binary(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, ip} -> public_ip?(ip)
      _ -> public_dns?(host)
    end
  end

  defp public_host?(_), do: false

  defp public_dns?(host) do
    host != "localhost" and String.contains?(host, ".") and
      Regex.match?(~r/\A[a-zA-Z0-9.-]+\z/, host) and not String.ends_with?(host, ".localhost")
  end

  defp public_ip?({a, b, _, _}) do
    a not in [0, 10, 127] and not (a == 172 and b in 16..31) and
      not (a == 192 and b == 168) and not (a == 169 and b == 254) and
      not (a == 100 and b in 64..127) and a < 224
  end

  defp public_ip?({0, 0, 0, 0, 0, 0, 0, value}) when value in [0, 1], do: false
  defp public_ip?({0, 0, 0, 0, 0, 0xFFFF, _, _}), do: false

  defp public_ip?({a, _, _, _, _, _, _, _}),
    do: a not in 0xFC00..0xFDFF and a not in 0xFE80..0xFEBF and a < 0xFF00

  defp certificate?(pem) do
    case :public_key.pem_decode(pem) do
      [{:Certificate, der, :not_encrypted}] ->
        :public_key.pkix_decode_cert(der, :otp)
        true

      _ ->
        false
    end
  end

  def discovery("/", _identity), do: envelope(["/1.0"])

  def discovery("/1.0", identity) do
    envelope(%{
      "api_version" => "1.0",
      "api_status" => "stable",
      "auth" => "untrusted",
      "public" => false,
      "auth_methods" => ["tls"],
      "api_extensions" => identity.api_extensions
    })
  end

  def envelope(metadata),
    do: %{"type" => "sync", "status" => "Success", "status_code" => 200, "metadata" => metadata}

  def rewrite(body, identity, limit) do
    with {:ok, %{"metadata" => %{"environment" => environment} = metadata} = envelope} <-
           Jason.decode(body),
         true <- is_map(environment),
         extensions when is_list(extensions) <- Map.get(metadata, "api_extensions", []) do
      environment =
        environment
        |> Map.put("addresses", identity.addresses)
        |> Map.put("certificate", identity.certificate)

      extensions = Enum.filter(extensions, &(&1 in identity.api_extensions))

      body =
        envelope
        |> Map.put(
          "metadata",
          metadata |> Map.put("environment", environment) |> Map.put("api_extensions", extensions)
        )
        |> Jason.encode!()

      if byte_size(body) <= limit, do: {:ok, body}, else: :error
    else
      _ -> :error
    end
  end
end
