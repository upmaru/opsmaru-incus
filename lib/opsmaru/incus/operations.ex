defmodule Opsmaru.Incus.Operations do
  @moduledoc """
  Shared, protocol-neutral Incus operations for agents and direct callers.

  Each operation is an `Opsmaru.Incus.Operations.Descriptor` with a canonical
  `incus_<resource>_<verb>` name, input/output JSON schemas, a required scope,
  a destructive-confirmation rule and bounds. `all/0` lists the exported
  operations; one whose client methods lack recorded evidence is never
  exported and appears in `unavailable/0` instead.

  `run/3` executes one operation synchronously in the caller's process:

  1. the host-verified `:scopes` must include the operation's scope;
  2. input must match the input schema and byte bounds;
  3. destructive operations require `confirm` to repeat the affected resource;
  4. restricted create/update input needs the host's `allow_restricted?/3`;
  5. the host's `binding/2` and `authorize/3` must succeed.

  Only then does the operation contact the backend, through the public
  `Opsmaru.Incus` client. A denial at any step makes no backend request.
  Nothing here starts a process, opens a connection or stores state; see
  `Opsmaru.Incus.Operations.Host` for the host contract.
  """
  alias Opsmaru.Incus
  alias Opsmaru.Incus.{Connection, Context}

  alias Opsmaru.Incus.Operations.{
    Descriptor,
    Evidence,
    Exec,
    Inspection,
    Instances,
    OperationTools,
    Result,
    Schema
  }

  @scopes ~w(incus.read incus.write incus.exec incus.delete)

  @unavailable [
    %{
      "name" => "incus_instance_copy",
      "reason" =>
        "deferred by scope (2026-11-04): copy and migration are not in the initial catalogue"
    },
    %{
      "name" => "incus_instance_rename",
      "reason" =>
        "deferred by scope (2026-11-04): copy and migration are not in the initial catalogue"
    },
    %{
      "name" => "incus_instance_move",
      "reason" =>
        "deferred by scope (2026-11-04): copy and migration are not in the initial catalogue"
    }
  ]

  @doc "The four scopes operations require."
  def scopes, do: @scopes

  @doc "Exported descriptors in canonical name order."
  def all, do: candidates() |> exported()

  @doc "Operations not exported: deferred by scope, or missing client evidence (with the missing requirements)."
  def unavailable do
    missing =
      for descriptor <- candidates(),
          (requirements = Evidence.missing(descriptor.requires)) != [],
          do: %{
            "name" => descriptor.name,
            "reason" => "missing client evidence",
            "missing" => requirements
          }

    Enum.sort_by(@unavailable ++ missing, & &1["name"])
  end

  @doc false
  def exported(descriptors) do
    descriptors
    |> Enum.filter(&(Evidence.missing(&1.requires) == []))
    |> Enum.sort_by(& &1.name)
  end

  @doc false
  def candidates,
    do:
      Inspection.descriptors() ++
        Instances.descriptors() ++ Exec.descriptors() ++ OperationTools.descriptors()

  @doc "Fetch an exported descriptor by canonical name."
  def fetch(name) do
    case Enum.find(all(), &(&1.name == name)) do
      nil -> :error
      descriptor -> {:ok, descriptor}
    end
  end

  @doc """
  Public contract of a descriptor as JSON-safe data: name, title, description,
  scope, destructive flag, confirmation rule, bounds, schemas and evidence.
  """
  def describe(%Descriptor{} = descriptor) do
    %{
      "name" => descriptor.name,
      "title" => descriptor.title,
      "description" => descriptor.description,
      "scope" => descriptor.scope,
      "destructive" => descriptor.destructive,
      "confirmation" => descriptor.confirmation,
      "bounds" => descriptor.bounds,
      "input_schema" => descriptor.input_schema,
      "output_schema" => output_schema(descriptor),
      "requires" => descriptor.requires
    }
  end

  @doc "The full output schema: the success result or an `error` object."
  def output_schema(%Descriptor{output_schema: success}) do
    %{"type" => "object", "oneOf" => [success, error_schema()]}
  end

  @doc false
  def error_schema do
    %{
      "type" => "object",
      "required" => ["error"],
      "properties" => %{
        "error" => %{
          "type" => "object",
          "required" => ["kind", "message"],
          "properties" => %{
            "kind" => %{"type" => "string"},
            "message" => %{"type" => "string"},
            "http_status" => %{"type" => "integer"},
            "error_code" => %{"type" => "integer"},
            "operation_id" => %{"type" => "string"},
            "required_scope" => %{"type" => "string"},
            "path" => %{"type" => "string"},
            "items" => %{"type" => "array", "items" => %{"type" => "string"}}
          },
          "additionalProperties" => false
        }
      },
      "additionalProperties" => false
    }
  end

  @doc """
  Run an exported operation. Options (all host-supplied, never tool input):

    * `:host` - module implementing `Opsmaru.Incus.Operations.Host`;
    * `:caller` - the host's authenticated caller term;
    * `:scopes` - the caller's verified scopes.

  Returns `{:ok, result}` or `{:error, %{"kind" => ..., "message" => ...}}`.
  """
  def run(name, input, opts) when is_binary(name) and is_list(opts) do
    case fetch(name) do
      {:ok, descriptor} -> execute(descriptor, input, opts)
      :error -> Result.error("unknown_operation", "no exported operation has this name")
    end
  end

  @doc false
  def execute(%Descriptor{} = descriptor, input, opts) do
    host = Keyword.get(opts, :host)
    caller = Keyword.get(opts, :caller)

    with :ok <- scope(descriptor, Keyword.get(opts, :scopes)),
         :ok <- validate(descriptor, input),
         :ok <- confirm(descriptor, input),
         :ok <- restricted(descriptor, host, caller, input),
         {:ok, binding} <- binding(host, caller, descriptor),
         :ok <- authorize(host, caller, descriptor, input),
         {:ok, input} <- resolve(descriptor, host, caller, input),
         {:ok, client} <- client(binding),
         {:ok, client} <- project(client, input) do
      env = %{host: host, caller: caller, descriptor: descriptor}

      case descriptor.run.(client, input, env) do
        {:ok, result} -> Result.within(result, descriptor.bounds["max_output_bytes"] || 262_144)
        {:error, %{"kind" => _}} = error -> error
        {:error, other} -> Result.client_error(other)
      end
    end
  end

  defp scope(descriptor, scopes) do
    if is_list(scopes) and descriptor.scope in scopes,
      do: :ok,
      else:
        Result.error("permission_denied", "the caller lacks the required scope", %{
          "required_scope" => descriptor.scope
        })
  end

  defp validate(descriptor, input) do
    max = descriptor.bounds["max_input_bytes"] || 65_536

    with true <- is_map(input) or :not_object,
         {:ok, json} <- Jason.encode(input),
         true <- byte_size(json) <= max or :too_large,
         :ok <- Schema.validate(descriptor.input_schema, input),
         :ok <- if(descriptor.check, do: descriptor.check.(input), else: :ok) do
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

  defp confirm(%Descriptor{confirm: nil}, _), do: :ok

  defp confirm(descriptor, input) do
    expected = descriptor.confirm.(input)

    if is_binary(expected) and input["confirm"] === expected,
      do: :ok,
      else:
        Result.error(
          "confirmation_required",
          "set confirm to #{inspect(expected)} to confirm this destructive operation"
        )
  end

  defp restricted(%Descriptor{restricted: nil}, _, _, _), do: :ok

  defp restricted(descriptor, host, caller, input) do
    case descriptor.restricted.(input) do
      [] ->
        :ok

      items ->
        if callback(host, :allow_restricted?, [caller, descriptor.name, items]) == {:ok, true},
          do: :ok,
          else:
            Result.error("restricted_input", "the host does not allow this restricted input", %{
              "items" => Enum.map(items, fn {kind, name} -> "#{kind}:#{name}" end)
            })
    end
  end

  defp binding(host, caller, descriptor) do
    case callback(host, :binding, [caller, descriptor.name]) do
      {:ok, {:ok, %Incus{} = client}} ->
        {:ok, client}

      {:ok, {:ok, %Connection{} = connection, %Context{} = context}} ->
        {:ok, {connection, context}}

      _ ->
        Result.error("host_binding_failed", "the host supplied no backend for this caller")
    end
  end

  defp authorize(host, caller, descriptor, input) do
    case callback(host, :authorize, [caller, descriptor.name, input]) do
      {:ok, :ok} -> :ok
      _ -> Result.error("unauthorized", "the host did not authorize this operation")
    end
  end

  defp resolve(%Descriptor{resolve: nil}, _, _, input), do: {:ok, input}

  defp resolve(descriptor, host, caller, input),
    do: descriptor.resolve.(input, fn name, args -> callback(host, name, [caller | args]) end)

  defp client(%Incus{} = client), do: {:ok, client}

  defp client({connection, context}) do
    case Incus.connect(connection, context) do
      {:ok, client} -> {:ok, client}
      {:error, error} -> Result.client_error(error)
    end
  end

  # `Opsmaru.Incus.project/2` raises on an invalid selection; the schema already
  # bounds `project`, so this guard only keeps a raise from escaping.
  defp project(client, %{"project" => project})
       when is_binary(project) and byte_size(project) in 1..1024,
       do: {:ok, Incus.project(client, project)}

  defp project(_client, %{"project" => _}),
    do: Result.error("invalid_input", "project is invalid", %{"path" => "/project"})

  defp project(client, _), do: {:ok, client}

  # A missing, raising or exiting host callback never reaches the backend.
  defp callback(host, name, args) do
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
