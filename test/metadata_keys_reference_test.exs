defmodule Opsmaru.Incus.MetadataKeysReferenceTest do
  use ExUnit.Case, async: false
  alias Opsmaru.Incus.{Error, Metadata, Model}
  @driver Path.expand("../.integration/metadata-keys-driver", __DIR__)

  setup_all do
    {out, status} =
      System.cmd("mise", ["exec", "--", "go", "build", "-o", @driver, "./metadatakeys"],
        cd: Path.expand("reference", __DIR__),
        env: [{"GOTOOLCHAIN", "local"}],
        stderr_to_stdout: true
      )

    assert status == 0, out
    :ok
  end

  test "native keys retain typed defaults, last-map-wins merge and null entries" do
    for keys <- [
          nil,
          [],
          [nil],
          [%{"a" => nil}],
          [
            %{"a" => %{"type" => "string", "shortdesc" => "first", "future" => "ignored"}},
            nil,
            %{
              "a" => %{
                "type" => "bool",
                "condition" => "container",
                "scope" => "global",
                "defaultdesc" => "default",
                "liveupdate" => "yes",
                "shortdesc" => "last",
                "longdesc" => "native"
              },
              "b" => %{}
            }
          ]
        ] do
      body = %{"configs" => %{"instance" => %{"limits" => %{"keys" => keys}}}}
      compare(body, "instance", "limits")
      {:ok, model} = Model.decode("MetadataConfiguration", body)

      assert Metadata.keys(model, "instance", "limits") ==
               Metadata.keys(body, "instance", "limits")

      assert model.data == body
    end
  end

  test "missing entity and group retain exact native quoted diagnostics" do
    for name <- [
          "",
          "private",
          "雪\"\\",
          <<0, 7, 8, 9, 10, 11, 12, 13, 127>>,
          "\u00a0\u00ad\u2028\uE000😀\u{10FFFF}"
        ] do
      compare(nil, name, "group")
      compare(%{"configs" => %{name => %{}}}, name, name)
    end

    compare(%{"configs" => %{"instance" => nil}}, "instance", "missing")
    compare(%{"configs" => %{"instance" => %{"group" => nil}}}, "instance", "group")
  end

  test "aliased-map codecs reject malformed entities, groups and typed keys" do
    for configs <- [
          [],
          %{"instance" => []},
          %{"instance" => %{"group" => []}},
          %{"instance" => %{"group" => %{"keys" => "bad"}}},
          %{"instance" => %{"group" => %{"keys" => [%{"a" => %{"type" => 7}}]}}}
        ] do
      body = %{"configs" => configs}
      refute oracle(body, "instance", "group")["ok"]
      assert {:error, :invalid_model} = Model.decode("MetadataConfiguration", body)
      assert {:error, %Error{kind: :invalid_metadata}} = Metadata.keys(body, "instance", "group")
    end
  end

  test "bounded names and payloads reject without exposing data or creating atoms" do
    assert {:error, %Error{kind: :invalid_metadata}} =
             Metadata.keys(%Model{type: "Server", data: %{}}, "entity", "group")

    for {body, entity, group} <- [
          {[], "entity", "group"},
          {%{}, nil, "group"},
          {%{}, "entity", <<255>>},
          {%{}, String.duplicate("private", 147), "group"},
          {%{
             "configs" => %{
               "private" => %{
                 "group" => %{
                   "keys" => [
                     %{
                       "a" => %{
                         "longdesc" => String.duplicate("private", 150_000)
                       }
                     }
                   ]
                 }
               }
             }
           }, "private", "group"}
        ] do
      assert {:error, %Error{kind: :invalid_metadata} = error} =
               Metadata.keys(body, entity, group)

      refute inspect(error) =~ "private"
    end

    Metadata.keys(%{}, "warm", "warm")
    before = :erlang.system_info(:atom_count)
    for n <- 1..100, do: Metadata.keys(%{}, "uninterned-#{n}", "group")
    assert :erlang.system_info(:atom_count) == before
  end

  defp compare(body, entity, group) do
    expected = oracle(body, entity, group)
    actual = Metadata.keys(body, entity, group)

    if expected["ok"] do
      assert {:ok, value} = actual
      assert value == expected["value"]
    else
      assert {:error, %Error{kind: :native_metadata, message: message} = error} = actual
      assert message == expected["error"]
      assert inspect(error) == "#Opsmaru.Incus.Error<native_metadata details redacted>"
    end
  end

  defp oracle(body, entity, group) do
    port = Port.open({:spawn_executable, @driver}, [:binary, :exit_status, :use_stdio])
    Port.command(port, Jason.encode!(%{body: body, entity: entity, group: group}) <> "\n")
    collect(port, "")
  end

  defp collect(port, data) do
    receive do
      {^port, {:data, bytes}} ->
        collect(port, data <> bytes)

      {^port, {:exit_status, 0}} ->
        Jason.decode!(data)

      {^port, {:exit_status, status}} ->
        flunk("native metadata keys oracle failed #{status}: #{data}")
    after
      5_000 ->
        Port.close(port)
        flunk("native metadata keys oracle deadline")
    end
  end
end
