defmodule Opsmaru.Incus.ImageInstances do
  @moduledoc """
  Native create/rebuild from an image on explicit Incus clients. Remote pulls
  require the host to approve the exact verified HTTPS source origin. No
  advertised address fallback, mutation replay or automatic operation wait.
  """
  alias Opsmaru.{Context, Incus}
  alias Opsmaru.Incus.{Error, Images, Model, Operation}

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
         true <- Keyword.keyword?(opts) and Keyword.keys(opts) -- [:approved_origin] == [],
         {:ok, image} <- Model.decode("Image", Model.encode(image)),
         true <-
           is_binary(image.data["fingerprint"]) and
             byte_size(image.data["fingerprint"]) in 1..1024,
         {:ok, request} <- Model.decode(type, Model.encode(request)),
         true <-
           Enum.all?(args, fn {_, value} -> is_binary(value) and byte_size(value) <= 1024 end),
         :ok <- instance_only(target, request.data),
         {:ok, fields, remote?} <-
           source_fields(target, source, image.data, request.data["source"] || %{}, opts) do
      case token(source, image.data, fields, remote?) do
        {:ok, fields, token_response} ->
          fields =
            Map.reject(fields, fn {key, value} ->
              key in ["alias", "fingerprint"] and value == ""
            end)

          body = Map.put(request.data, "source", fields)

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
    else
      {:error, %Error{} = error} -> {:error, error}
      _ -> {:error, %Error{kind: :invalid_image_arguments}}
    end
  end

  defp source_fields(target, source, image, fields, opts) when is_map(fields) do
    local =
      target.connection.transport == source.connection.transport and
        target.connection.address == source.connection.address and
        (target.connection.project || "default") == (source.connection.project || "default") and
        target.connection.member == source.connection.member

    fields = Map.put(fields, "type", "image")

    if local do
      {:ok, Map.merge(fields, %{"fingerprint" => image["fingerprint"], "alias" => ""}), false}
    else
      if source.connection.transport == :https and
           opts[:approved_origin] == URI.to_string(source.connection.address) do
        alias_name = fields["alias"] || ""
        use_alias = is_binary(alias_name) and alias_name != "" and image["public"] == true

        {:ok,
         Map.merge(fields, %{
           "mode" => "pull",
           "protocol" => "incus",
           "server" => opts[:approved_origin],
           "certificate" => (source.server.environment || %{})["certificate"] || "",
           "fingerprint" => if(use_alias, do: "", else: image["fingerprint"]),
           "alias" => if(use_alias, do: alias_name, else: "")
         }), true}
      else
        {:error, %Error{kind: :unapproved_image_origin}}
      end
    end
  end

  defp token(source, image, fields, true) do
    if image["public"] == true do
      {:ok, fields, nil}
    else
      case Images.image_secret(source, image["fingerprint"]) do
        {:ok, response} -> {:ok, Map.put(fields, "secret", response.metadata), response}
        error -> error
      end
    end
  end

  defp token(_, _, fields, false), do: {:ok, fields, nil}

  defp instance_only(target, %{"source" => %{"instance_only" => true}}),
    do: Incus.require_extension(target, "container_only_migration")

  defp instance_only(_, _), do: :ok
end
