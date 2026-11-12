defmodule Mix.Tasks.Opsmaru.Incus.Inventory do
  use Mix.Task

  @shortdoc "Generate the official Incus client inventory from a verified checkout"
  @moduledoc """
  Run `mix opsmaru.incus.inventory --source .integration/incus-reference`.
  The source checkout must be clean and at the exact pinned commit. `--output`
  selects an alternate inventory file for reproducibility/update comparisons.
  Requires the root mise Go toolchain; no Go code is part of the gateway.
  """

  @impl true
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [source: :string, output: :string])

    if rest != [] or invalid != [] or is_nil(opts[:source]) do
      Mix.raise("usage: mix opsmaru.incus.inventory --source PATH [--output PATH]")
    end

    source = Path.expand(opts[:source])
    reference_file = Path.expand("priv/incus/reference.json")
    reference = Jason.decode!(File.read!(reference_file))
    revision = command!("git", ["-C", source, "rev-parse", "HEAD"]) |> String.trim()

    if revision != reference["revision"], do: Mix.raise("Incus reference revision mismatch")

    if command!("git", ["-C", source, "status", "--porcelain", "--untracked-files=all"]) != "" do
      Mix.raise("Incus reference must be a clean checkout")
    end

    output = Path.expand(opts[:output] || "priv/incus/inventory.json")

    # Erlang's launcher can reorder PATH. Reapply mise instead of selecting an
    # unrelated Homebrew Go binary against the inherited pinned GOROOT.
    version = command!("mise", ["exec", "--", "go", "version"])

    unless String.starts_with?(version, "go version go#{reference["go"]} "),
      do: Mix.raise("Incus verification Go version mismatch")

    inventory =
      command!(
        "mise",
        ["exec", "--", "go", "run", "scripts/incus-inventory.go", source, reference_file],
        env: [{"GO111MODULE", "off"}, {"GOTOOLCHAIN", "local"}]
      )

    parsed = Jason.decode!(inventory)
    if parsed["entries"] == [], do: Mix.raise("empty Incus inventory")
    File.write!(output, inventory)
    Mix.shell().info("Generated #{length(parsed["entries"])} entries at #{output}")
  end

  defp command!(command, args, opts \\ []) do
    case System.cmd(command, args, opts) do
      {out, 0} -> out
      {_out, _status} -> Mix.raise("#{command} reference verification failed")
    end
  end
end
