defmodule Opsmaru.Incus.ImageSource do
  @moduledoc false
  # What a target is told about a remote image source, as the pinned
  # GetConnectionInfo reports it: an Incus server or an OCI registry.
  alias Opsmaru.Incus.{Error, OCI}

  def oci?(source), do: is_struct(source, OCI)

  def protocol(source), do: if(oci?(source), do: "oci", else: "incus")

  def certificate(%OCI{certificate: certificate}), do: certificate
  def certificate(client), do: (client.server.environment || %{})["certificate"] || ""

  # ProtocolOCI.GetConnectionInfo has no project; an Incus source has its own.
  def project(source), do: if(oci?(source), do: "", else: source.connection.project || "default")

  # ProtocolOCI.GetImageSecret: OCI registries have no private images.
  def private_image(source) do
    if oci?(source),
      do:
        {:error,
         %Error{kind: :native, message: "Private images aren't supported with OCI registry"}},
      else: :ok
  end

  def credentials?(nil), do: true

  def credentials?({username, password}),
    do: text?(username) and (is_nil(password) or text?(password))

  def credentials?(_), do: false

  defp text?(value), do: is_binary(value) and byte_size(value) <= 4096 and String.valid?(value)

  # Go sends the registry URL it was given, user information included, escaped as
  # url.User and url.UserPassword escape it. The origin itself carries none.
  def server(origin, nil), do: origin

  def server(origin, {username, password}) do
    userinfo =
      if is_nil(password),
        do: escape(username),
        else: escape(username) <> ":" <> escape(password)

    URI.to_string(%{URI.parse(origin) | userinfo: userinfo})
  end

  # net/url shouldEscape(c, encodeUserPassword): unreserved and $&+,;= stay as is.
  defp escape(value), do: URI.encode(value, &(&1 in ~c"-_.~$&+,;=" or alnum?(&1)))

  defp alnum?(c), do: c in ?a..?z or c in ?A..?Z or c in ?0..?9
end
