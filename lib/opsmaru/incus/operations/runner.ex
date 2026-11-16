defmodule Opsmaru.Incus.Operations.Runner do
  @moduledoc false
  # The trust checks shared by `Operations.Composite.run/3` and
  # `Operations.Native.run/3`. Each returns `:ok`/`{:ok, value}` or a tool
  # error, and none contacts the backend except `client/1`, which runs only
  # after the host bound and authorized the call.
  alias Opsmaru.Incus
  alias Opsmaru.Incus.{Connection, Context}
  alias Opsmaru.Incus.Operations.{Result, Schema}

  @doc "The host-verified scopes must include the operation's scope."
  def scope(required, scopes) do
    if is_list(scopes) and required in scopes,
      do: :ok,
      else:
        Result.error("permission_denied", "the caller lacks the required scope", %{
          "required_scope" => required
        })
  end

  @doc "Input is a JSON object within `max` bytes that matches `schema`, then passes `check`."
  def validate(schema, input, max, components \\ %{}, check \\ nil) do
    with true <- is_map(input) or :not_object,
         {:ok, json} <- Jason.encode(input),
         true <- byte_size(json) <= max or :too_large,
         :ok <- Schema.validate(schema, input, components),
         :ok <- if(check, do: check.(input), else: :ok) do
      :ok
    else
      :too_large ->
        Result.error("invalid_input", "the input exceeds #{max} bytes")

      {:error, path, reason} ->
        Result.error("invalid_input", "#{display(path)} #{reason}", %{"path" => path})

      _ ->
        Result.error("invalid_input", "the input must be a JSON object")
    end
  end

  defp display(""), do: "input"
  defp display(path), do: String.trim_leading(path, "/")

  @doc "Restricted input needs the host's `allow_restricted?/3`."
  def restricted([], _host, _caller, _operation), do: :ok

  def restricted(items, host, caller, operation) do
    if callback(host, :allow_restricted?, [caller, operation, items]) == {:ok, true},
      do: :ok,
      else:
        Result.error("restricted_input", "the host does not allow this restricted input", %{
          "items" => Enum.map(items, fn {kind, name} -> "#{kind}:#{name}" end)
        })
  end

  @doc "The host's backend for this caller: a client, or a connection and context."
  def binding(host, caller, operation) do
    case callback(host, :binding, [caller, operation]) do
      {:ok, {:ok, %Incus{} = client}} ->
        {:ok, client}

      {:ok, {:ok, %Connection{} = connection, %Context{} = context}} ->
        {:ok, {connection, context}}

      _ ->
        Result.error("host_binding_failed", "the host supplied no backend for this caller")
    end
  end

  def authorize(host, caller, operation, input) do
    case callback(host, :authorize, [caller, operation, input]) do
      {:ok, :ok} -> :ok
      _ -> Result.error("unauthorized", "the host did not authorize this operation")
    end
  end

  @doc "The bound client, discovered first when the host returned a connection and context."
  def client(%Incus{} = client), do: {:ok, client}

  def client({connection, context}) do
    case Incus.connect(connection, context) do
      {:ok, client} -> {:ok, client}
      {:error, error} -> Result.client_error(error)
    end
  end

  # `Opsmaru.Incus.project/2` raises on an invalid selection; the schema already
  # bounds `project`, so this guard only keeps a raise from escaping.
  @doc "Select the native project named in validated, authorized input."
  def project(client, %{"project" => project})
      when is_binary(project) and byte_size(project) in 1..1024,
      do: {:ok, Incus.project(client, project)}

  def project(_client, %{"project" => _}),
    do: Result.error("invalid_input", "project is invalid", %{"path" => "/project"})

  def project(client, _), do: {:ok, client}

  # A missing, raising or exiting host callback never reaches the backend.
  @doc "Call a host callback: `{:ok, result}`, `:missing` or `:failed`."
  def callback(host, name, args) do
    if is_atom(host) and Code.ensure_loaded?(host) and
         function_exported?(host, name, length(args)),
       do: {:ok, apply(host, name, args)},
       else: :missing
  rescue
    _ -> :failed
  catch
    _, _ -> :failed
  end
end
