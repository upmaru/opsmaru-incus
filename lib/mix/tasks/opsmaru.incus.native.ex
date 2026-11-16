defmodule Mix.Tasks.Opsmaru.Incus.Native do
  use Mix.Task

  alias Opsmaru.Incus.Operations.Native.Generator

  @shortdoc "Generate the native Incus operations document"
  @moduledoc """
  Run `mix opsmaru.incus.native` to regenerate
  `priv/incus/native-operations.json` from `methods.json`, `models.json`, the
  coverage evidence, `native-policy.json` and the pinned `rest-api.yaml`
  (descriptive text only, read after its SHA-256 is verified).

  The output is deterministic. `--check` regenerates in memory and fails
  unless the file on disk is byte for byte identical; `--output PATH` writes
  elsewhere. This is a development task: the Hex package does not ship
  `rest-api.yaml`.
  """

  @impl true
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [check: :boolean, output: :string])

    if rest != [] or invalid != [],
      do: Mix.raise("usage: mix opsmaru.incus.native [--check] [--output PATH]")

    directory = Path.expand("priv/incus")
    output = Path.expand(opts[:output] || Path.join(directory, "native-operations.json"))

    generated =
      with {:ok, inputs} <- Generator.load(directory),
           {:ok, generated} <- Generator.build(inputs) do
        generated
      else
        {:error, reasons} ->
          Mix.raise("native operations generation failed:\n  " <> Enum.join(reasons, "\n  "))
      end

    bytes = Generator.encode(generated)
    exported = map_size(generated["document"]["paths"])
    summary = "#{exported} exported, #{length(generated["unavailable"])} unavailable"

    cond do
      !opts[:check] ->
        File.write!(output, bytes)
        Mix.shell().info("wrote #{Path.relative_to_cwd(output)} (#{summary})")

      File.read(output) == {:ok, bytes} ->
        Mix.shell().info("#{Path.relative_to_cwd(output)} is up to date (#{summary})")

      true ->
        Mix.raise(
          "#{Path.relative_to_cwd(output)} is stale: run `mix opsmaru.incus.native` and review the diff"
        )
    end
  end
end
