defmodule Opsmaru.Incus.ImageSource do
  @moduledoc false
  # What a target is told about a remote image source, as the pinned
  # GetConnectionInfo reports it: an Incus server, an OCI registry or a
  # SimpleStreams server.
  alias Opsmaru.Incus.{Error, OCI, SimpleStreams}

  def oci?(source), do: is_struct(source, OCI)

  # A server that only serves images, never the same backend as an Incus target.
  def image_server?(source), do: oci?(source) or is_struct(source, SimpleStreams)

  def protocol(%OCI{}), do: "oci"
  def protocol(%SimpleStreams{}), do: "simplestreams"
  def protocol(_), do: "incus"

  def certificate(%OCI{certificate: certificate}), do: certificate
  def certificate(%SimpleStreams{certificate: certificate}), do: certificate
  def certificate(client), do: (client.server.environment || %{})["certificate"] || ""

  # Image servers report no project; an Incus source has its own.
  def project(source),
    do: if(image_server?(source), do: "", else: source.connection.project || "default")

  # The image servers' GetImageSecret: they have no private images.
  def private_image(%OCI{}),
    do:
      {:error,
       %Error{kind: :native, message: "Private images aren't supported with OCI registry"}}

  def private_image(%SimpleStreams{}),
    do:
      {:error,
       %Error{
         kind: :native,
         message: "Private images aren't supported by the simplestreams protocol"
       }}

  def private_image(_), do: :ok

  # The image servers' ExportImage, which a push copy calls after its token.
  def export(%OCI{} = source), do: OCI.unsupported(source, "ExportImage")
  def export(%SimpleStreams{} = source), do: SimpleStreams.unsupported(source, "ExportImage")

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
