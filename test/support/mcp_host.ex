if Code.ensure_loaded?(TamaMCP.Server) do
  defmodule Opsmaru.TestSupport.MCPHost do
    @moduledoc """
    Fixture MCP host composing the shared Incus tools with one host tool.

    Its authorization adapter maps an `x-test-token` header to scopes and puts
    the operations host module in the decision's assigns, as a real host does
    after verifying a bearer credential. The backend binding comes from the
    plug's `authorization_options`, never from the request.
    """
    alias Opsmaru.Incus.Operations

    defmodule Cache do
      @moduledoc "Uncached validator loader for tests."
      @behaviour TamaMCP.Cache
      @impl true
      def fetch(_key, loader, _options), do: {:ok, loader.()}
    end

    defmodule Authorization do
      @moduledoc "Token-to-scope adapter for tests."
      use TamaMCP.Authorization
      alias TamaMCP.Authorization.Decision

      @impl true
      def authenticate(conn, options) do
        case Plug.Conn.get_req_header(conn, "x-test-token") do
          [token] when token in ["read", "all", "nohost", "none"] ->
            {:ok,
             %Decision{
               principal: "agent-" <> token,
               scopes: scopes(token),
               assigns: assigns(token, options)
             }}

          _ ->
            {:error, TamaMCP.Error.invalid_request("unknown test token")}
        end
      end

      defp scopes("read"), do: ["incus.read", "host.read"]
      defp scopes("none"), do: []
      defp scopes(_), do: Operations.scopes() ++ ["host.read"]

      defp assigns("nohost", options), do: %{binding: options[:binding]}

      defp assigns(_, options),
        do: %{opsmaru_incus_host: Opsmaru.TestSupport.MCPHost.Binding, binding: options[:binding]}
    end

    defmodule Binding do
      @moduledoc "Operations host that reads the trusted binding from the decision assigns."
      @behaviour Opsmaru.Incus.Operations.Host

      @impl true
      def binding(%TamaMCP.Context{assigns: %{binding: {connection, context}}}, _operation),
        do: {:ok, connection, context}

      @impl true
      def authorize(%TamaMCP.Context{principal: "agent-" <> _}, _operation, _input), do: :ok
    end

    defmodule Status do
      @moduledoc "A host-owned tool registered beside the shared ones."
      use TamaMCP.Tool,
        task: :disabled,
        scopes: ["host.read"],
        title: "Host status",
        description: "Report the fixture host status."

      raw_output_schema(%{
        "type" => "object",
        "properties" => %{"status" => %{"type" => "string"}},
        "required" => ["status"],
        "additionalProperties" => false
      })

      @impl true
      def call(_input, _context),
        do: {:ok, TamaMCP.Response.success(structured_content: %{"status" => "ok"})}
    end

    defmodule Server do
      @moduledoc "One endpoint: shared Incus tools plus the host tool."
      use TamaMCP.Server, name: "fixture-host", version: "1.0.0"
      alias Opsmaru.Incus.MCP.Tools
      require Tools
      Tools.register()
      tool(Status, name: "host_status")
    end
  end
end
