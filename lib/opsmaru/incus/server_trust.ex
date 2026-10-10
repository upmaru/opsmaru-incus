defmodule Opsmaru.Incus.ServerTrust do
  @moduledoc false
  require Record

  Record.defrecordp(
    :cert_record,
    :OTPCertificate,
    Record.extract(:OTPCertificate, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecordp(
    :tbs_record,
    :OTPTBSCertificate,
    Record.extract(:OTPTBSCertificate, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecordp(
    :validity_record,
    :Validity,
    Record.extract(:Validity, from_lib: "public_key/include/public_key.hrl")
  )

  # Pinning never disables peer/hostname verification. Only trust-anchor errors
  # may be resolved by an exact host-supplied pin; expiry/signature errors fail.
  def verify(cert, {:bad_cert, reason}, %{ca: false} = state)
      when reason in [:unknown_ca, :selfsigned_peer],
      do: peer(cert, state)

  def verify(_, {:bad_cert, _}, _), do: {:fail, :server_identity}
  def verify(_, {:extension, _}, state), do: {:unknown, state}
  def verify(_, :valid, state), do: {:valid, state}
  def verify(cert, :valid_peer, state), do: peer(cert, state)

  defp peer(cert, state) do
    der = if is_binary(cert), do: cert, else: :public_key.pkix_encode(:OTPCertificate, cert, :otp)

    hostname =
      :public_key.pkix_verify_hostname(cert, [dns_id: state.hostname, ip: state.hostname],
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      )

    if :crypto.hash(:sha256, der) == state.digest and hostname and current?(der),
      do: {:valid, state},
      else: {:fail, :server_identity}
  rescue
    _ -> {:fail, :server_identity}
  end

  defp current?(der) do
    validity =
      :public_key.pkix_decode_cert(der, :otp)
      |> cert_record(:tbsCertificate)
      |> tbs_record(:validity)

    now = :calendar.datetime_to_gregorian_seconds(:calendar.universal_time())
    before = validity |> validity_record(:notBefore) |> timestamp()
    after_time = validity |> validity_record(:notAfter) |> timestamp()
    now >= before and now <= after_time
  end

  defp timestamp({kind, value}) do
    value = to_string(value)

    {year, rest} =
      case {kind, value} do
        {:utcTime, <<year::binary-size(2), rest::binary>>} ->
          year = String.to_integer(year)
          {if(year >= 50, do: 1900 + year, else: 2000 + year), rest}

        {:generalTime, <<year::binary-size(4), rest::binary>>} ->
          {String.to_integer(year), rest}
      end

    <<month::binary-size(2), day::binary-size(2), hour::binary-size(2), minute::binary-size(2),
      second::binary-size(2), "Z">> = rest

    :calendar.datetime_to_gregorian_seconds(
      {{year, String.to_integer(month), String.to_integer(day)},
       {String.to_integer(hour), String.to_integer(minute), String.to_integer(second)}}
    )
  end
end
