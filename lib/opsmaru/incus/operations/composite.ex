defmodule Opsmaru.Incus.Operations.Composite do
  @moduledoc """
  The composite Incus operations: shared, protocol-neutral operations for
  agents and direct callers. `Opsmaru.Incus.Operations.Native` holds the native
  client operations.

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
  alias Opsmaru.Incus.Operations.Composite.{Exec, Inspection, Instances, OperationTools}
  alias Opsmaru.Incus.Operations.{Descriptor, Evidence, Fragments, Result, Runner}

  @scopes ~w(incus.read incus.write incus.exec incus.delete)
  @version Mix.Project.config()[:version]

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
    %{"type" => "object", "oneOf" => [success, Fragments.error_schema()]}
  end

  @doc """
  The exported operations as a `tama-operations/1` document (an OpenAPI 3.1
  document with `x-tama-*` extensions), source `opsmaru_incus`.

  Plain JSON-safe data, the same on every call for a release, with operations
  in name order. Each operation maps field for field from its descriptor; its
  `200` response is the success result and `default` is the shared error
  object, `{"error": {"kind", "message", ...}}`. `run/3` is the executor: a
  host returns its `{:ok, result}` as the `200` result and wraps the map of
  its `{:error, error}` as `{"error": error}`. Unavailable operations are not
  listed.
  """
  def openapi do
    %{
      "openapi" => "3.1.1",
      "jsonSchemaDialect" => "https://spec.openapis.org/oas/3.1/dialect/base",
      "info" => %{"title" => "opsmaru_incus operations", "version" => @version},
      "x-tama-profile" => "tama-operations/1",
      "x-tama-source" => "opsmaru_incus",
      "paths" => Map.new(all(), &{"/operations/" <> &1.name, %{"post" => operation(&1)}})
    }
  end

  defp operation(%Descriptor{} = descriptor) do
    %{
      "operationId" => descriptor.name,
      "summary" => descriptor.title,
      "description" => descriptor.description,
      "tags" => [resource(descriptor.name)],
      "x-tama-scopes" => [descriptor.scope],
      "x-tama-destructive" => descriptor.destructive,
      "x-tama-bounds" => descriptor.bounds,
      "x-opsmaru-requires" => descriptor.requires,
      "requestBody" => %{"required" => true, "content" => json(descriptor.input_schema)},
      "responses" => %{
        "200" => %{"description" => "Result", "content" => json(descriptor.output_schema)},
        "default" => %{"description" => "Error", "content" => json(Fragments.error_schema())}
      }
    }
    |> confirmation(descriptor.confirmation)
    |> identity(descriptor.output_schema)
  end

  defp json(schema), do: %{"application/json" => %{"schema" => schema}}

  # The resource in `incus_<resource>_<verb>`.
  defp resource("incus_" <> rest),
    do: rest |> String.split("_") |> Enum.drop(-1) |> Enum.join("_")

  defp confirmation(operation, %{"field" => field, "value" => value}),
    do: Map.put(operation, "x-tama-confirmation", %{"field" => field, "description" => value})

  defp confirmation(operation, _), do: operation

  defp identity(operation, %{"properties" => %{"operation_id" => _, "status" => _}}),
    do: Map.put(operation, "x-tama-identity", ["operation_id", "status"])

  defp identity(operation, _), do: operation

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
    name = descriptor.name
    max_input = descriptor.bounds["max_input_bytes"] || 65_536

    with :ok <- Runner.scope(descriptor.scope, Keyword.get(opts, :scopes)),
         :ok <- Runner.validate(descriptor.input_schema, input, max_input, %{}, descriptor.check),
         :ok <- confirm(descriptor, input),
         :ok <- Runner.restricted(restricted(descriptor, input), host, caller, name),
         {:ok, binding} <- Runner.binding(host, caller, name),
         :ok <- Runner.authorize(host, caller, name, input),
         {:ok, input} <- resolve(descriptor, host, caller, input),
         {:ok, client} <- Runner.client(binding),
         {:ok, client} <- Runner.project(client, input) do
      env = %{host: host, caller: caller, descriptor: descriptor}

      case descriptor.run.(client, input, env) do
        {:ok, result} -> Result.within(result, descriptor.bounds["max_output_bytes"] || 262_144)
        {:error, %{"kind" => _}} = error -> error
        {:error, other} -> Result.client_error(other)
      end
    end
  end

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

  defp restricted(%Descriptor{restricted: nil}, _), do: []
  defp restricted(descriptor, input), do: descriptor.restricted.(input)

  defp resolve(%Descriptor{resolve: nil}, _, _, input), do: {:ok, input}

  defp resolve(descriptor, host, caller, input) do
    descriptor.resolve.(input, fn name, args -> Runner.callback(host, name, [caller | args]) end)
  end
end
