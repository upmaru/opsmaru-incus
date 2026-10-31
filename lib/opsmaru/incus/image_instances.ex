defmodule Opsmaru.Incus.ImageInstances do
  @moduledoc """
  Native create/rebuild from an image on explicit Incus clients. Remote pulls
  require the host to approve the exact verified HTTPS source origin. No
  advertised address fallback, mutation replay or automatic operation wait.

  The source may be a resolved `OCI` value, as for the pinned helpers: the target
  pulls with protocol `oci`, the registry certificate and the caller's own source
  project. `:registry_credentials` (`{username, password}`) adds Go's escaped user
  information to the server URL for a private registry.
  """
  alias Opsmaru.Incus
  alias Opsmaru.Incus.{Context, Error, Images, ImageSource, Model, NativeInput, Operation}

  def create(target, source, image, request, opts \\ []),
    do: issue(target, source, image, "CreateInstance", %{}, "InstancesPost", request, opts)

  def rebuild(target, source, image, name, request, opts \\ []) do
    with :ok <- Incus.require_extension(target, "instances_rebuild") do
      issue(
        target,
        source,
        image,
        "RebuildInstance",
        %{"name" => name},
        "InstanceRebuildPost",
        request,
        opts
      )
    end
  end

  defp issue(target, source, image, method, args, type, request, opts) do
    with :ok <- Context.authorize(target.context, target.connection),
         :ok <- Context.authorize(source.context, source.connection),
         true <-
           Keyword.keyword?(opts) and
             Keyword.keys(opts) -- [:approved_origin, :registry_credentials] == [] and
             ImageSource.credentials?(opts[:registry_credentials]) and
             (is_nil(opts[:registry_credentials]) or ImageSource.oci?(source)),
         {:ok, image} <- Model.decode("Image", Model.encode(image)),
         true <-
           is_binary(image.data["fingerprint"]) and
             byte_size(image.data["fingerprint"]) in 1..1024,
         {:ok, request} <- NativeInput.cast(type, Model.encode(request)),
         {:ok, request} <- Model.decode(type, request),
         true <-
           Enum.all?(args, fn {_, value} -> is_binary(value) and byte_size(value) <= 1024 end),
         :ok <- instance_only(target, request.data),
         :ok <- source_project(source, request.data["source"] || %{}),
         {:ok, fields, remote?} <-
           source_fields(target, source, image.data, request.data["source"] || %{}, opts) do
      issue_with_token(target, source, image.data, request.data, fields, remote?, method, args)
    else
      {:error, %Error{} = error} -> {:error, error}
      _ -> {:error, %Error{kind: :invalid_image_arguments}}
    end
  end

  defp issue_with_token(target, source, image, request, fields, remote?, method, args) do
    case token(source, image, fields, remote?) do
      {:ok, fields, token_response} ->
        fields =
          Map.reject(fields, fn {key, value} ->
            key in ["alias", "fingerprint"] and value == ""
          end)

        body = Map.put(request, "source", fields)

        with {:ok, response} <- Incus.call(target, method, args, body: body),
             {:ok, operation} <- Operation.from_response(target, response) do
          {:ok, operation}
        else
          {:error, %Error{} = error} ->
            if token_response,
              do: {:error, %{error | response: %{source: token_response, error: error}}},
              else: {:error, error}
        end

      error ->
        error
    end
  end

  defp source_fields(target, source, image, fields, opts) when is_map(fields) do
    local = same_backend?(target, source)

    fields = Map.put(fields, "type", "image")

    if local do
      {:ok, Map.merge(fields, %{"fingerprint" => image["fingerprint"], "alias" => ""}), false}
    else
      if source.connection.transport == :https and
           opts[:approved_origin] == URI.to_string(source.connection.address) do
        alias_name = fields["alias"] || ""
        use_alias = is_binary(alias_name) and alias_name != "" and image["public"] == true

        fields =
          fields
          |> Map.merge(%{
            "mode" => "pull",
            "protocol" => ImageSource.protocol(source),
            "server" => ImageSource.server(opts[:approved_origin], opts[:registry_credentials]),
            "project" => image_project(source, fields),
            "certificate" => ImageSource.certificate(source),
            "fingerprint" => if(use_alias, do: "", else: image["fingerprint"]),
            "alias" => if(use_alias, do: alias_name, else: "")
          })
          # Go omits an empty source project.
          |> Map.reject(fn {key, value} -> key == "project" and value == "" end)

        {:ok, fields, true}
      else
        {:error, %Error{kind: :unapproved_image_origin}}
      end
    end
  end

  # The pinned helper keeps the caller's source project; an OCI registry has none of
  # its own, while an Incus source keeps its bound selection (approved difference).
  defp image_project(source, fields) do
    if ImageSource.oci?(source),
      do: fields["project"] || "",
      else: source.connection.project || fields["project"] || ""
  end

  defp source_project(source, fields) do
    if ImageSource.oci?(source) or
         fields["project"] in [nil, "", source.connection.project || "default"],
       do: :ok,
       else: {:error, %Error{kind: :image_project_mismatch}}
  end

  defp same_backend?(target, source),
    do:
      target.connection.transport == source.connection.transport and
        target.connection.address == source.connection.address and
        (target.connection.project || "default") == (source.connection.project || "default") and
        target.connection.member == source.connection.member

  defp token(source, image, fields, true) do
    if image["public"] == true do
      {:ok, fields, nil}
    else
      with :ok <- ImageSource.private_image(source),
           {:ok, response} <- Images.image_secret(source, image["fingerprint"]) do
        {:ok, Map.put(fields, "secret", response.metadata), response}
      end
    end
  end

  defp token(_, _, fields, false), do: {:ok, fields, nil}

  defp instance_only(target, %{"source" => %{"instance_only" => true}}),
    do: Incus.require_extension(target, "container_only_migration")

  defp instance_only(_, _), do: :ok
end
