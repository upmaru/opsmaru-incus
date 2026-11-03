if Code.ensure_loaded?(TamaMCP.Tool) do
  defmodule Opsmaru.Incus.MCP.Tools do
    @moduledoc """
    Optional TamaMCP binding: one `TamaMCP.Tool` module per exported operation.

    Compiled only when the host depends on `:tama_mcp`. Each tool module has the
    descriptor's scope and schemas, `task: :disabled` and a `call/2` that runs
    the shared operation synchronously; nothing starts a process, endpoint or
    task store. Register them on the host's own server under their canonical
    names, next to host tools:

        defmodule MyHost.MCP do
          use TamaMCP.Server, name: "my-host", version: "1.0.0"
          require Opsmaru.Incus.MCP.Tools
          Opsmaru.Incus.MCP.Tools.register()
          tool MyHost.Tools.Status, name: "my_host_status"
        end

    The host's TamaMCP authorization adapter supplies the trust: it puts its
    `Opsmaru.Incus.Operations.Host` module in the decision's assigns under
    `:opsmaru_incus_host`. The verified scopes and the `TamaMCP.Context` (as
    the caller) come from the same decision. Without that assign every call
    is denied before backend access.
    """
    alias Opsmaru.Incus.Operations

    @tools for descriptor <- Operations.all(),
               do:
                 {descriptor.name,
                  Module.concat(
                    __MODULE__,
                    Macro.camelize(String.replace_prefix(descriptor.name, "incus_", ""))
                  )}

    @doc "`{canonical_name, tool_module}` for every exported operation, in name order."
    def all, do: @tools

    @doc "The tool module for a canonical name, or `nil`."
    def module(name), do: Enum.find_value(@tools, fn {tool, module} -> tool == name && module end)

    @doc "Register every shared tool on the calling `TamaMCP.Server` under its canonical name."
    defmacro register do
      for {name, module} <- @tools do
        quote do: tool(unquote(module), name: unquote(name))
      end
    end

    @doc false
    def call(name, input, %TamaMCP.Context{} = context) do
      host = Map.get(context.assigns || %{}, :opsmaru_incus_host)

      case Operations.run(name, input, host: host, caller: context, scopes: context.scopes) do
        {:ok, result} ->
          {:ok, TamaMCP.Response.success(content: [text(result)], structured_content: result)}

        {:error, error} ->
          result = %{"error" => error}
          {:ok, TamaMCP.Response.tool_error(content: [text(result)], structured_content: result)}
      end
    end

    defp text(result), do: TamaMCP.Response.text(Jason.encode!(result))
  end

  for descriptor <- Opsmaru.Incus.Operations.all() do
    module = Opsmaru.Incus.MCP.Tools.module(descriptor.name)
    output = Opsmaru.Incus.Operations.output_schema(descriptor)

    contents =
      quote do
        @moduledoc """
        `#{unquote(descriptor.name)}`: #{unquote(descriptor.description)}

        Scope `#{unquote(descriptor.scope)}`. Generated from
        `Opsmaru.Incus.Operations`; register it under `canonical_name/0`.
        """
        use TamaMCP.Tool,
          task: :disabled,
          scopes: unquote([descriptor.scope]),
          title: unquote(descriptor.title),
          description: unquote(descriptor.description)

        raw_input_schema(unquote(Macro.escape(descriptor.input_schema)))
        raw_output_schema(unquote(Macro.escape(output)))

        @doc "The canonical tool name this module must be registered under."
        def canonical_name, do: unquote(descriptor.name)

        @impl true
        def call(input, context),
          do: Opsmaru.Incus.MCP.Tools.call(unquote(descriptor.name), input, context)
      end

    Module.create(module, contents, Macro.Env.location(__ENV__))
  end
end
