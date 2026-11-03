defmodule FoundationConsumer.MCP.RuntimeStatus do
  @moduledoc "A host-owned tool composed beside the shared ones."
  use TamaMCP.Tool,
    task: :disabled,
    scopes: ["runtime.read"],
    description: "Report whether the host runtime is ready."

  @impl true
  def call(_input, _context) do
    ready = Agent.get(FoundationConsumer.Runtime, & &1)
    {:ok, TamaMCP.Response.success(structured_content: %{"ready" => ready})}
  end
end

defmodule FoundationConsumer.IncusHost do
  @moduledoc "Host binding: the trusted backend comes from host state, never tool input."
  @behaviour Opsmaru.Incus.Operations.Host

  @impl true
  def binding(%TamaMCP.Context{assigns: %{backend: {connection, context}}}, _operation),
    do: {:ok, connection, context}

  def binding(_caller, _operation), do: {:error, :no_backend}

  @impl true
  def authorize(_caller, _operation, input),
    do: if(Map.get(input, "project", "default") == "default", do: :ok, else: {:error, :project})
end

defmodule FoundationConsumer.MCP do
  @moduledoc "Host-owned MCP server: the shared Incus tools plus a host runtime tool."
  use TamaMCP.Server, name: "foundation-consumer", version: "0.1.0"
  alias Opsmaru.Incus.MCP.Tools
  require Tools
  Tools.register()
  tool(FoundationConsumer.MCP.RuntimeStatus, name: "consumer_runtime_status")
end
