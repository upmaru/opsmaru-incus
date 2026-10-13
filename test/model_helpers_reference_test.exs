defmodule Opsmaru.Incus.ModelHelpersReferenceTest do
  use ExUnit.Case, async: false
  alias Opsmaru.Incus.{Model, ModelURL, Status}
  @driver Path.expand("../.integration/model-helpers-driver", __DIR__)
  @schemas Jason.decode!(File.read!(Path.expand("../priv/incus/models.json", __DIR__)))[
             "models"
           ]

  setup_all do
    {out, status} =
      System.cmd("mise", ["exec", "--", "go", "build", "-o", @driver, "./modelhelpers"],
        cd: Path.expand("reference", __DIR__),
        env: [{"GOTOOLCHAIN", "local"}],
        stderr_to_stdout: true
      )

    assert status == 0, out
    :ok
  end

  for type <- Model.writable_types() do
    test "#{type}.Writable agrees with every populated native writable field and drops read-only data" do
      type = unquote(type)
      fields = @schemas[type <> "Put"]["fields"]
      data = Map.new(fields, fn field -> {field["name"], sample(field["type"], 0)} end)

      input =
        Map.merge(data, %{
          "readonly_fixture" => "must-drop",
          "unknown_future" => %{"secret" => "private"}
        })

      # Read-only fields from the actual containing DTO are present as well.
      input =
        Enum.reduce(@schemas[type]["fields"], input, fn field, acc ->
          Map.put_new(acc, field["name"], sample(field["type"], 0))
        end)

      expected = reference(type, input)
      assert {:ok, model} = Model.decode(type, input)
      assert {:ok, writable} = Model.writable(model)
      assert writable.type == type <> "Put"
      assert Model.encode(writable) == expected
      refute Map.has_key?(writable.data, "readonly_fixture")
      refute Map.has_key?(writable.data, "unknown_future")
      # The original remains lossless and can still be used for reconciliation.
      assert Model.encode(model) == input
      refute inspect(writable) =~ "private"
    end
  end

  test "writable projection preserves host-visible nulls and absence, and rejects unsupported helpers" do
    assert {:ok, model} = Model.decode("Instance", %{"config" => nil, "name" => "native"})
    assert {:ok, writable} = Model.writable(model)
    assert writable.data == %{"config" => nil}

    assert {:error, :unsupported_model_helper} =
             Model.writable(%Model{type: "Operation", data: %{}})

    assert {:error, :unsupported_model_helper} = Model.writable(nil)
  end

  test "all native statuses and unknown codes preserve names, finality and instance activity" do
    for code <- Enum.to_list(100..113) ++ [200, 400, 401, -1, 0, 199, 201, 777] do
      for name <- [Status.string(code), "unknown", "running"] do
        expected = oracle(%{action: "status", code: code, text: name})
        assert Status.string(code) == expected["name"]
        assert Status.final?(code) == expected["final"]
        assert Status.from_string(name) == expected["parsed"]

        assert {:ok, active} =
                 Model.active?(%Model{type: "Instance", data: %{"status_code" => code}})

        assert active == expected["active"]
      end
    end

    assert {:error, :unsupported_model_helper} = Model.active?(nil)
  end

  test "native resource URLs preserve path escaping, project/target suppression and snapshot identity" do
    types =
      ~w(Certificate Image Instance NetworkACL Profile Project StorageBucket StorageBucketKey StorageVolume)

    for type <- types,
        name <- ["native", "space +/:;,@&=$?#%雪", "parent/snapshot/part"],
        project <- ["default", "other +雪"] do
      body = %{
        "name" => name,
        "fingerprint" => name,
        "project" => project,
        "location" => "member",
        "type" => "custom"
      }

      {args, opts} =
        case type do
          type when type in ["Certificate", "Project"] ->
            {["1.0"], []}

          "StorageVolume" ->
            {["1.0", "pool +雪"], [pool: "pool +雪"]}

          "StorageBucket" ->
            {["1.0", "pool +雪", project], [pool: "pool +雪", project: project]}

          "StorageBucketKey" ->
            {["1.0", "pool +雪", project, "bucket +雪"],
             [pool: "pool +雪", project: project, bucket: "bucket +雪"]}

          _ ->
            {["1.0", project], [project: project]}
        end

      assert {:ok, model} = Model.decode(type, body)
      expected = oracle(%{action: "url", type: type, body: body, args: args})
      assert {:ok, actual} = ModelURL.resource(model, opts)
      assert actual == expected
      assert URI.parse(actual).host == nil
    end

    for name <- ["", "parent", "parent/snapshot", "/", "a/b/c"] do
      assert Tuple.to_list(ModelURL.parent_snapshot_name(name)) ==
               oracle(%{action: "snapshot-name", text: name})
    end

    assert {:ok, bucket} =
             Model.decode("StorageBucket", %{"name" => "bucket", "location" => "none"})

    assert {:ok, "/1.0/storage-pools/p/buckets/bucket"} =
             ModelURL.resource(bucket, pool: "p", project: "default")

    assert {:error, :invalid_model_url} = ModelURL.resource(bucket, [])

    assert {:error, :invalid_model_url} =
             ModelURL.resource(bucket, pool: "p", origin: "https://unapproved.example")

    assert {:error, :unsupported_model_helper} = ModelURL.resource(nil)
  end

  test "native Etag input tuples preserve ordered field values, including bucket key secrets" do
    for type <- ~w(NetworkForward NetworkLoadBalancer NetworkPeer StorageBucket StorageBucketKey) do
      complete = Map.new(@schemas[type]["fields"], &{&1["name"], sample(&1["type"], 0)})

      for data <- [complete, %{}] do
        expected = oracle(%{action: "etag", type: type, body: data})
        assert {:ok, model} = Model.decode(type, data)
        assert {:ok, values} = Model.etag_values(model)
        assert values == expected
        assert Model.encode(model) == data
      end
    end

    assert {:error, :unsupported_model_helper} = Model.etag_values(nil)
  end

  defp sample("*" <> type, depth), do: sample(type, depth)
  defp sample(type, _) when type in ["[]byte", "[]uint8"], do: Base.encode64(<<0, 255, 128>>)
  defp sample("[]" <> type, depth), do: [sample(type, depth + 1)]
  defp sample("map[string]" <> type, depth), do: %{"native" => sample(type, depth + 1)}
  defp sample("string", _), do: "native"
  defp sample("bool", _), do: true
  defp sample("time.Time", _), do: "2026-10-10T12:00:00Z"

  defp sample(type, _)
       when type in ~w(int int8 int16 int32 int64 uint uint8 uint16 uint32 uint64 float32 float64),
       do: 7

  defp sample(type, depth) do
    case @schemas[type] do
      %{"kind" => "struct", "fields" => fields} when depth < 6 ->
        Map.new(fields, &{&1["name"], sample(&1["type"], depth + 1)})

      %{"underlying" => underlying} ->
        sample(underlying, depth + 1)

      _ ->
        %{"native" => true}
    end
  end

  defp reference(type, data) do
    oracle(%{type: type, body: data})
  end

  defp oracle(input) do
    port = Port.open({:spawn_executable, @driver}, [:binary, :exit_status, :use_stdio])
    Port.command(port, Jason.encode!(input) <> "\n")
    collect(port, "")
  end

  defp collect(port, data) do
    receive do
      {^port, {:data, bytes}} -> collect(port, data <> bytes)
      {^port, {:exit_status, 0}} -> Jason.decode!(data)
      {^port, {:exit_status, status}} -> flunk("native model oracle failed #{status}: #{data}")
    after
      5_000 ->
        Port.close(port)
        flunk("native model oracle deadline")
    end
  end
end
