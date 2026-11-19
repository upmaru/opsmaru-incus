defmodule Opsmaru.Incus.ClientArgsReferenceTest do
  @moduledoc """
  The pinned client argument structs against `Opsmaru.Incus.ClientArgs`.
  The field sets come from the unchanged structs by reflection; the request
  effect of every mapped option is compared with the pinned methods in
  `copy_negotiation_reference_test.exs` and `image_copy_contract_test.exs`,
  which derive their Elixir options from the same Go-shaped args through
  `ClientArgs.options/2`.
  """
  use ExUnit.Case, async: true
  alias Opsmaru.Incus.{ClientArgs, Error}
  @driver Path.expand("../.integration/client-args-driver", __DIR__)
  @inventory Jason.decode!(File.read!(Path.expand("../priv/incus/inventory.json", __DIR__)))[
               "entries"
             ]

  setup_all do
    {out, status} =
      System.cmd("mise", ["exec", "--", "go", "build", "-o", @driver, "./clientargs"],
        cd: Path.expand("reference", __DIR__),
        env: [{"GOTOOLCHAIN", "local"}],
        stderr_to_stdout: true
      )

    assert status == 0, out
    {out, 0} = System.cmd(@driver, [], stderr_to_stdout: true)
    %{native: Jason.decode!(out)}
  end

  test "every mapped struct is a pinned client declaration", %{native: native} do
    assert ClientArgs.types() == native |> Map.keys() |> Enum.sort()

    for type <- ClientArgs.types() do
      assert Enum.any?(@inventory, &(&1["id"] == "client/type/" <> type)), type
    end
  end

  for type <-
        ~w(ImageCopyArgs InstanceCopyArgs InstanceSnapshotCopyArgs StoragePoolVolumeCopyArgs StoragePoolVolumeMoveArgs) do
    test "#{type} maps every pinned field once, with its Go type and in declaration order", %{
      native: native
    } do
      type = unquote(type)
      shape = native[type]

      assert Enum.map(ClientArgs.fields(type), fn {name, go_type, _} ->
               %{"name" => name, "type" => go_type}
             end) == shape["fields"]

      assert ClientArgs.embedded(type) == shape["embedded"]

      options = for {_, _, {:option, key}} <- ClientArgs.fields(type), do: key
      assert options == Enum.uniq(options)

      {module, function, arity} = ClientArgs.function(type)
      assert Code.ensure_loaded?(module) and function_exported?(module, function, arity)
    end
  end

  test "only fields the pinned method never reads are unmapped" do
    for type <- ClientArgs.types(), {name, _, {:ignored, reason}} <- ClientArgs.fields(type) do
      assert type == "StoragePoolVolumeMoveArgs", name
      assert reason =~ "MoveStoragePoolVolume"
    end
  end

  test "zero values are unset as in Go; lists, including an empty one, are kept" do
    assert ClientArgs.options("ImageCopyArgs", %{
             "Aliases" => [%{"name" => "a", "description" => ""}],
             "AutoUpdate" => false,
             "CopyAliases" => true,
             "Public" => false,
             "Type" => "",
             "Mode" => "push",
             "Profiles" => []
           }) ==
             {:ok,
              [
                aliases: [%{"name" => "a", "description" => ""}],
                copy_aliases: true,
                mode: "push",
                profiles: []
              ]}

    assert ClientArgs.options("ImageCopyArgs", %{Profiles: nil, Mode: ""}) == {:ok, []}

    assert ClientArgs.options("InstanceCopyArgs", %{
             Name: "copy",
             Live: true,
             InstanceOnly: true,
             Mode: "relay",
             Refresh: true,
             RefreshExcludeOlder: true,
             AllowInconsistent: true
           }) ==
             {:ok,
              [
                name: "copy",
                live: true,
                instance_only: true,
                mode: :relay,
                refresh: true,
                refresh_exclude_older: true,
                allow_inconsistent: true
              ]}

    assert ClientArgs.options("InstanceSnapshotCopyArgs", %{Name: "", Mode: "pull", Live: true}) ==
             {:ok, [mode: :pull, live: true]}

    assert ClientArgs.options("StoragePoolVolumeCopyArgs", %{VolumeOnly: true, Mode: "push"}) ==
             {:ok, [mode: :push, volume_only: true]}
  end

  test "a move drops the promoted copy fields the pinned method never sends" do
    assert ClientArgs.options("StoragePoolVolumeMoveArgs", %{
             Name: "renamed",
             Mode: "push",
             VolumeOnly: true,
             Refresh: true,
             RefreshExcludeOlder: true,
             Project: "other"
           }) == {:ok, [name: "renamed", project: "other"]}
  end

  test "unknown structs, fields, types and modes are rejected" do
    invalid = {:error, %Error{kind: :invalid_client_args}}

    for {type, native} <- [
          {"InstanceCopyArgs", %{Mode: "bogus"}},
          {"ImageCopyArgs", %{"Mode" => :push}},
          {"InstanceCopyArgs", %{name: "lower-case"}},
          {"InstanceCopyArgs", %{Name: "x", Unknown: true}},
          {"InstanceCopyArgs", %{Live: "yes"}},
          {"InstanceCopyArgs", %{Name: 1}},
          {"InstanceCopyArgs", %{"Name" => "a", Name: "b"}},
          {"ImageCopyArgs", %{Profiles: ["ok", 1]}},
          {"ImageCopyArgs", %{Profiles: "default"}},
          {"ImageCopyArgs", %{Aliases: [%{"name" => "a", "target" => "f"}]}},
          {"ImageCopyArgs", %{Aliases: [%{"name" => 1}]}},
          {"ImageCopyArgs", %{Aliases: ["a"]}},
          {"ImageCreateArgs", %{}},
          {"InstanceCopyArgs", [Name: "x"]}
        ] do
      assert ClientArgs.options(type, native) == invalid, inspect({type, native})
    end
  end
end
