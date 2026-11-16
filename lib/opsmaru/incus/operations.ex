defmodule Opsmaru.Incus.Operations do
  @moduledoc """
  Shared Incus operations for agents and direct callers.

  Operations live in two namespaces:

    * `Opsmaru.Incus.Operations.Composite` - the composite
      `incus_<resource>_<verb>` operations;
    * `Opsmaru.Incus.Operations.Native` - the native client operations.

  Shared infrastructure stays here: the `Opsmaru.Incus.Operations.Host`
  behaviour, descriptors, schemas, results and evidence.

  The functions on this module are the 0.1.0 entry points. Through 0.2.x they
  delegate to `Opsmaru.Incus.Operations.Composite` and return exactly what it
  returns; they are removed in 0.3.0.
  """
  alias Opsmaru.Incus.Operations.Composite

  @deprecated "Use Opsmaru.Incus.Operations.Composite.scopes/0"
  defdelegate scopes(), to: Composite

  @deprecated "Use Opsmaru.Incus.Operations.Composite.all/0"
  defdelegate all(), to: Composite

  @deprecated "Use Opsmaru.Incus.Operations.Composite.unavailable/0"
  defdelegate unavailable(), to: Composite

  @deprecated "Use Opsmaru.Incus.Operations.Composite.fetch/1"
  defdelegate fetch(name), to: Composite

  @deprecated "Use Opsmaru.Incus.Operations.Composite.describe/1"
  defdelegate describe(descriptor), to: Composite

  @deprecated "Use Opsmaru.Incus.Operations.Composite.output_schema/1"
  defdelegate output_schema(descriptor), to: Composite

  @deprecated "Use Opsmaru.Incus.Operations.Composite.run/3"
  defdelegate run(name, input, opts), to: Composite
end
