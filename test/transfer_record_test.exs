defmodule Opsmaru.Incus.TransferRecordTest do
  # Provenance of the initial Macus transfer. `source_sha256` and
  # `transferred_sha256` are the historical record of the transfer and are
  # never rewritten; a destination amended later also carries an
  # `amended_sha256` and a one-sentence `amendment`, so a consumer holding
  # only the Hex package verifies the shipped bytes without Git history.
  use ExUnit.Case, async: true

  @record "priv/incus/transfer.json"
  @digest ~r/\A[0-9a-f]{64}\z/

  describe "provenance" do
    test "every files entry exists and hashes to its current digest" do
      for file <- Jason.decode!(File.read!(@record))["files"] do
        expected = file["amended_sha256"] || file["transferred_sha256"]

        actual =
          :crypto.hash(:sha256, File.read!(file["destination"]))
          |> Base.encode16(case: :lower)

        which =
          if file["amended_sha256"], do: "amendment", else: "transfer"

        assert actual == expected,
               "#{file["destination"]} differs from its recorded #{which} digest; " <>
                 "update priv/incus/transfer.json deliberately"
      end
    end

    test "amendments are non-empty, distinct from the transfer, and only where amended" do
      for file <- Jason.decode!(File.read!(@record))["files"] do
        if amended = file["amended_sha256"] do
          amendment = file["amendment"]

          assert is_binary(amendment) and amendment != "",
                 "#{file["destination"]} has an amended digest without an amendment"

          assert amended != file["transferred_sha256"],
                 "#{file["destination"]} repeats its transferred digest as an amendment"
        else
          refute file["amendment"],
                 "#{file["destination"]} carries an amendment without an amended digest"
        end
      end
    end

    test "identifiers keep their recorded values and shape" do
      record = Jason.decode!(File.read!(@record))

      assert record["source_repository"] == "https://github.com/upmaru/macus"
      assert record["source_revision"] =~ ~r/\A[0-9a-f]{40}\z/
      assert record["reference_revision"] == "13f3992766142d5087fff2e362cd2e1a75294fe8"

      for file <- record["files"] do
        for key <- ["source_sha256", "transferred_sha256"] do
          assert file[key] =~ @digest,
                 "#{file["destination"]} has a malformed #{key}"
        end

        if amended = file["amended_sha256"] do
          assert amended =~ @digest,
                 "#{file["destination"]} has a malformed amended_sha256"
        end
      end
    end

    test "an altered copy is detected" do
      file =
        Jason.decode!(File.read!(@record))["files"] |> Enum.find(& &1["amended_sha256"])

      altered = File.read!(file["destination"]) <> "\n# local edit\n"
      expected = file["amended_sha256"] || file["transferred_sha256"]

      refute :crypto.hash(:sha256, altered) |> Base.encode16(case: :lower) == expected
    end
  end
end
