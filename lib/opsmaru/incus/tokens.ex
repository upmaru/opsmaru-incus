defmodule Opsmaru.Incus.Tokens do
  @moduledoc """
  Pure native certificate/cluster token helpers. These format existing Incus
  operation metadata; they never create credentials, trust or runtime state.
  Encoded tokens and model data are privileged values and must not be logged.
  """
  alias Opsmaru.Incus.{Error, Model, NativeInput, Operation}
  @limit 1_048_576

  def certificate(operation), do: from_operation(operation, "CertificateAddToken")
  def cluster(operation), do: from_operation(operation, "ClusterMemberJoinToken")

  @doc "Native JSON/base64 representation, including native field order and HTML escaping."
  def encode(%Model{type: type, data: data})
      when type in ["CertificateAddToken", "ClusterMemberJoinToken"] do
    with :ok <- bounded(data),
         {:ok, native} <- NativeInput.cast(type, data) do
      name = if type == "CertificateAddToken", do: "client_name", else: "server_name"
      fields = [name, "fingerprint", "addresses", "secret", "expires_at"]

      json =
        "{" <>
          Enum.map_join(fields, ",", &(Jason.encode!(&1) <> ":" <> native_json(native[&1]))) <>
          "}"

      {:ok, Base.encode64(json)}
    else
      _ -> invalid()
    end
  end

  def encode(_), do: invalid()

  defp native_json(nil), do: "null"

  defp native_json(values) when is_list(values),
    do: "[" <> Enum.map_join(values, ",", &native_json/1) <> "]"

  defp native_json(value) when is_binary(value),
    do: "\"" <> (value |> String.to_charlist() |> Enum.map_join(&escape/1)) <> "\""

  defp escape(?"), do: "\\\""
  defp escape(?\\), do: "\\\\"
  defp escape(?\b), do: "\\b"
  defp escape(?\t), do: "\\t"
  defp escape(?\n), do: "\\n"
  defp escape(?\f), do: "\\f"
  defp escape(?\r), do: "\\r"

  defp escape(char) when char < 32 or char in [?<, ?>, ?&, 0x2028, 0x2029],
    do:
      "\\u" <> (char |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(4, "0"))

  defp escape(char), do: <<char::utf8>>

  defp from_operation(%Operation{} = operation, type),
    do: from_operation(%Model{type: "Operation", data: Operation.data(operation)}, type)

  defp from_operation(%Model{type: "Operation", data: data}, type) when is_map(data) do
    with :ok <- bounded(data),
         metadata when is_map(metadata) <- data["metadata"],
         {:ok, name} <- name(metadata, type),
         true <- is_binary(metadata["secret"]) and is_binary(metadata["fingerprint"]),
         addresses when is_list(addresses) <- metadata["addresses"],
         true <- Enum.all?(addresses, &is_binary/1),
         {:ok, expiry} <- expiry(metadata["expiresAt"], type),
         {:ok, token} <-
           Model.decode(type, %{
             name_field(type) => name,
             "secret" => metadata["secret"],
             "fingerprint" => metadata["fingerprint"],
             "addresses" => addresses,
             "expires_at" => expiry
           }) do
      {:ok, token}
    else
      _ -> invalid()
    end
  end

  defp from_operation(_, _), do: invalid()
  defp name_field("CertificateAddToken"), do: "client_name"
  defp name_field("ClusterMemberJoinToken"), do: "server_name"

  defp name(%{"request" => %{"name" => value}}, "CertificateAddToken") when is_binary(value),
    do: {:ok, value}

  defp name(%{"serverName" => value}, "ClusterMemberJoinToken") when is_binary(value),
    do: {:ok, value}

  defp name(_, _), do: :error

  defp expiry(value, "CertificateAddToken") when not is_binary(value),
    do: NativeInput.cast("time.Time", nil)

  defp expiry(value, _) when is_binary(value), do: NativeInput.cast("time.Time", value)
  defp expiry(_, _), do: :error

  defp bounded(data) do
    case Jason.encode(data) do
      {:ok, bytes} when byte_size(bytes) <= @limit -> :ok
      _ -> :error
    end
  end

  defp invalid, do: {:error, %Error{kind: :invalid_token}}
end
