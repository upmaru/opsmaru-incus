defmodule Opsmaru.Incus.OperationsTamaDexTest do
  # tama_dex is a dev/test-only dependency: these tests prove the documents
  # conform to the profile and index together, as a host such as Macus loads
  # them. The library itself never calls tama_dex.
  use ExUnit.Case, async: true
  alias Opsmaru.Incus.Operations.{Composite, Native}
  alias Opsmaru.TestSupport.{OperationsFixture, OperationsHost, ProfileChecks}
  alias Tama.Dex

  import OperationsFixture, only: [sync: 1, sync: 2, native_error: 2, accepted: 1]

  @uuid "01234567-89ab-cdef-0123-456789abcdef"
  @cassette "opsmaru_incus"
  @all Composite.scopes() ++ Native.scopes()

  # A host adapter, as Macus registers one per source: it adds the host
  # module and the verified caller, and wraps the error map as `default`.
  defmodule Executor do
    @behaviour Tama.Dex.Executor

    @impl true
    def execute(%Tama.Dex.Call{} = call, input) do
      run = Keyword.fetch!(call.opts, :run)

      case run.(call.operation_id, input,
             host: OperationsHost,
             caller: call.context,
             scopes: call.scopes
           ) do
        {:ok, result} -> {:ok, result}
        {:error, error} -> {:error, %{"error" => error}}
      end
    end
  end

  @executors %{
    "opsmaru_incus" => {Executor, run: &Composite.run/3},
    "opsmaru_incus_native" => {Executor, run: &Native.run/3}
  }

  setup do
    index = start_supervised!({Dex.Index, path: :memory})
    %{index: index}
  end

  defp load!(index) do
    for document <- [Composite.openapi(), Native.openapi()] do
      assert {:ok, loaded} = Dex.load(index, document, cassette: @cassette)
      loaded
    end
  end

  defp ids(index, query, opts) do
    {:ok, %{results: results}} =
      Dex.search(index, query, Keyword.merge([limit: 20, include_schemas: false], opts))

    Enum.map(results, & &1.operation_id)
  end

  test "both documents pass Tama.Dex.Profile.validate/1" do
    for {document, source, count} <- [
          {Composite.openapi(), "opsmaru_incus", 32},
          {Native.openapi(), "opsmaru_incus_native", 274}
        ] do
      assert {:ok, %Dex.Document{} = validated} = Dex.Profile.validate(document)
      assert validated.source == source
      assert validated.profile == "tama-operations/1"
      assert validated.version == Mix.Project.config()[:version]
      assert length(validated.operations) == count

      # The same holds for the document as a host reads it from JSON.
      assert {:ok, %Dex.Document{digest: digest}} =
               document |> Jason.encode!() |> Jason.decode!() |> Dex.Profile.validate()

      assert digest == validated.digest
    end
  end

  test "tama-dex rejects what the structural checks reject" do
    document = Composite.openapi()
    path = "/operations/incus_image_delete"

    for broken <- [
          Map.put(document, "x-tama-profile", "tama-operations/2"),
          Map.put(document, "x-tama-unknown", true),
          put_in(document, ["paths", path, "post", "x-tama-scopes"], []),
          put_in(document, ["paths", path, "post", "x-tama-identity"], ["missing"]),
          put_in(document, ["paths", path, "post", "x-tama-confirmation"], %{
            "field" => "wait_seconds",
            "description" => "x"
          })
        ] do
      assert {:error, [issue | _]} = Dex.Profile.validate(broken)
      assert is_binary(issue.pointer) and is_atom(issue.code)
      assert ProfileChecks.issues(broken) != []
    end
  end

  test "both documents load into one index as the opsmaru_incus cassette", %{index: index} do
    assert [
             %{cassette: @cassette, source: "opsmaru_incus", operations: 32, changed: true},
             %{
               cassette: @cassette,
               source: "opsmaru_incus_native",
               operations: 274,
               changed: true
             }
           ] = load!(index)

    # Loading again changes nothing and reports no duplicate operation.
    assert [%{changed: false}, %{changed: false}] = load!(index)

    assert [%{cassette: @cassette, kind: :local, status: :ready, sources: sources}] =
             Dex.cassettes(index)

    assert Enum.map(sources, &{&1.source, &1.operations}) ==
             [{"opsmaru_incus", 32}, {"opsmaru_incus_native", 274}]
  end

  test "search finds operations from both sources", %{index: index} do
    load!(index)

    assert "incus_instance_delete" in ids(index, "incus_instance_delete", scopes: @all)

    assert "incus_native_delete_instance" in ids(index, "incus_native_delete_instance",
             scopes: @all
           )

    composite = ids(index, "instance", scopes: @all, source: "opsmaru_incus")
    native = ids(index, "instance", scopes: @all, source: "opsmaru_incus_native")

    assert composite != [] and
             Enum.all?(composite, &(not String.starts_with?(&1, "incus_native_")))

    assert native != [] and Enum.all?(native, &String.starts_with?(&1, "incus_native_"))

    # Upstream descriptions make native operations findable by what they do.
    assert "incus_native_get_network_zone_records" in ids(index, "network zone records",
             scopes: @all
           )

    {:ok, %{results: [result | _]}} =
      Dex.search(index, "incus_native_delete_instance", scopes: @all)

    assert result.cassette == @cassette
    assert result.source == "opsmaru_incus_native"
    assert result.destructive == true
    assert result.scopes == ["incus.native.delete"]

    assert result.confirmation == %{field: "confirm", description: "the exact value of `name`"}
  end

  test "composite scopes neither find nor describe native operations", %{index: index} do
    load!(index)
    composite = Composite.scopes()

    found = ids(index, "incus_native_delete_instance", scopes: composite)
    refute Enum.any?(found, &String.starts_with?(&1, "incus_native_"))
    assert ids(index, nil, scopes: composite, source: "opsmaru_incus_native") == []
    assert ids(index, nil, scopes: composite) != []

    assert {:error, :not_found} =
             Dex.describe(index, @cassette, "incus_native_delete_instance", scopes: composite)

    assert {:ok, described} =
             Dex.describe(index, @cassette, "incus_native_delete_instance",
               scopes: Native.scopes()
             )

    assert described.identity == ["operation_id"]
    assert described.extensions["x-opsmaru-requires"] == ["DeleteInstance"]
    assert described.extensions["x-opsmaru-native"]["method"] == "DeleteInstance"

    assert {:ok, described} =
             Dex.describe(index, @cassette, "incus_instance_delete", scopes: composite)

    assert described.identity == ["operation_id", "status"]
    assert described.extensions["x-opsmaru-requires"] == ["DeleteInstance", "GetOperationWait"]

    assert {:error, %Dex.Error{dispatched: false}} =
             Dex.execute(
               index,
               @cassette,
               "incus_native_delete_instance",
               %{"name" => "web", "confirm" => "web"},
               scopes: composite,
               executors: @executors
             )

    for unavailable <- ~w(incus_native_exec_instance incus_instance_copy) do
      assert {:error, :not_found} = Dex.describe(index, @cassette, unavailable, scopes: @all)
    end
  end

  describe "execute through the host executors" do
    setup %{index: index} do
      load!(index)
      root = OperationsFixture.root()
      on_exit(fn -> File.rm_rf!(root) end)

      fixture =
        OperationsFixture.start(root, :gen_tcp, fn request ->
          case {request.method, OperationsFixture.path(request)} do
            {"GET", "/1.0/instances"} ->
              sync([%{"name" => "web", "type" => "container", "config" => nil, "new" => [1]}])

            {"GET", "/1.0/instances/web"} ->
              sync(%{"name" => "web", "status_code" => 103}, %{"etag" => "abc"})

            {"GET", "/1.0/instances/gone"} ->
              native_error(404, "Instance not found")

            {"GET", "/1.0/profiles"} ->
              sync(["/1.0/profiles/default"])

            {"PATCH", "/1.0/instances/web"} ->
              sync(%{})

            {"DELETE", "/1.0/instances/web"} ->
              accepted(@uuid)

            _ ->
              :next
          end
        end)

      %{fixture: fixture, caller: %{binding: {fixture.connection, fixture.context}}}
    end

    defp execute(index, operation, input, caller, scopes \\ @all) do
      Dex.execute(index, @cassette, operation, input,
        scopes: scopes,
        executors: @executors,
        context: caller
      )
    end

    test "native results match their 200 schemas", %{index: index, caller: caller} do
      assert {:ok, %{source: "opsmaru_incus_native", result: result}} =
               execute(index, "incus_native_get_instances", %{"instance_type" => ""}, caller)

      assert %{"kind" => "list", "metadata" => [%{"name" => "web", "new" => [1]}]} = result

      assert {:ok, %{result: %{"kind" => "model", "etag" => "abc"}}} =
               execute(index, "incus_native_get_instance", %{"name" => "web"}, caller)

      assert {:ok, %{result: %{"kind" => "names", "metadata" => ["default"]}}} =
               execute(index, "incus_native_get_profile_names", %{}, caller)

      assert {:ok, %{result: %{"kind" => "empty_sync"}}} =
               execute(
                 index,
                 "incus_native_patch_instance",
                 %{"name" => "web", "etag" => "abc", "body" => %{"description" => "d"}},
                 caller
               )

      assert {:ok, %{result: %{"kind" => "operation", "operation_id" => @uuid}}} =
               execute(
                 index,
                 "incus_native_delete_instance",
                 %{"name" => "web", "confirm" => "web"},
                 caller
               )
    end

    test "executor errors match the default schema", %{index: index, caller: caller} do
      assert {:error,
              %{operation_error: %{"error" => %{"kind" => "native", "http_status" => 404}}}} =
               execute(index, "incus_native_get_instance", %{"name" => "gone"}, caller)

      assert {:error, %{operation_error: %{"error" => %{"kind" => "confirmation_mismatch"}}}} =
               execute(
                 index,
                 "incus_native_delete_instance",
                 %{"name" => "web", "confirm" => "db"},
                 caller
               )

      assert {:error, %{operation_error: %{"error" => %{"kind" => "unauthorized"}}}} =
               execute(
                 index,
                 "incus_native_get_instance",
                 %{"name" => "web"},
                 Map.put(caller, :authorize, fn _, _ -> {:error, :no} end)
               )
    end

    test "tama-dex rejects invalid native input before the executor", %{
      index: index,
      caller: caller,
      fixture: fixture
    } do
      body = %{"name" => "web", "source" => %{"type" => "image", "server" => "https://remote"}}

      for {operation, input} <- [
            {"incus_native_create_instance", %{"body" => body}},
            {"incus_native_delete_instance", %{"name" => "web"}},
            {"incus_native_get_instance", %{"name" => "web", "socket" => "/x"}}
          ] do
        assert {:error, %Dex.Error{dispatched: false}} = execute(index, operation, input, caller)
      end

      assert OperationsFixture.backend_requests(fixture) == []
    end

    test "composite results match their schemas too", %{index: index, caller: caller} do
      assert {:ok, %{source: "opsmaru_incus", result: %{"items" => [%{"name" => "web"}]}}} =
               execute(index, "incus_instance_list", %{}, caller)

      assert {:error, %{operation_error: %{"error" => %{"kind" => "confirmation_required"}}}} =
               execute(
                 index,
                 "incus_instance_delete",
                 %{"name" => "web", "confirm" => "db"},
                 caller
               )
    end
  end
end
