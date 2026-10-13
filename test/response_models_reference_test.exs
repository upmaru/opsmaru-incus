defmodule Opsmaru.Incus.ResponseModelsReferenceTest do
  use ExUnit.Case, async: false
  alias Opsmaru.Incus.{Error, Model, Response}

  @driver Path.expand("../../.integration/response-models-driver", __DIR__)
  @fields ~w(type status status_code operation error_code error metadata)

  setup_all do
    {out, status} =
      System.cmd("mise", ["exec", "--", "go", "build", "-o", @driver, "./responsemodels"],
        cd: Path.expand("../reference", __DIR__),
        env: [{"GOTOOLCHAIN", "local"}],
        stderr_to_stdout: true
      )

    assert status == 0, out
    :ok
  end

  for type <- ~w(Response ResponseRaw) do
    test "#{type}: populated, empty, null and future-type fields match native JSON" do
      type = unquote(type)

      values = [
        nil,
        %{},
        Map.new(@fields, &{&1, nil}),
        %{
          "type" => "future",
          "status" => "雪\n",
          "status_code" => 103,
          "operation" => "/1.0/operations/native",
          "error_code" => 409,
          "error" => "native conflict",
          "metadata" => %{"private" => [nil, true, "value", 7, 1.25]},
          "future" => "discarded"
        }
      ]

      for {body, native} <- Enum.zip(Enum.map(values, &Jason.encode!/1), oracle(type, values)) do
        assert native["accepted"]
        assert {:ok, %Model{type: ^type, data: data}} = Response.decode_native(type, body)
        assert_native(type, data, native)
        assert Enum.sort(Map.keys(data)) == Enum.sort(@fields)
      end
    end

    test "#{type}: field types and signed int64 boundaries match native rejection" do
      type = unquote(type)

      cases =
        for field <- @fields -- ["metadata"],
            bad <-
              if(field in ~w(status_code error_code),
                do: [
                  "7",
                  true,
                  [],
                  %{},
                  1.5,
                  9_223_372_036_854_775_808,
                  -9_223_372_036_854_775_809
                ],
                else: [7, true, [], %{}]
              ),
            do: %{field => bad}

      for {value, native} <- Enum.zip(cases, oracle(type, cases)) do
        refute native["accepted"], inspect(value)

        assert {:error, %Error{kind: :invalid_response_model}} =
                 Response.decode_native(type, Jason.encode!(value))

        assert {:error, :invalid_model} = Model.decode(type, value)
      end

      for value <- [-9_223_372_036_854_775_808, 9_223_372_036_854_775_807] do
        compare(type, [%{"status_code" => value, "error_code" => value}])
      end
    end
  end

  test "ResponseType is an open string alias, including the native null zero value" do
    compare("ResponseType", [nil, "", "sync", "async", "error", "future", "雪\u0000"])

    for {value, native} <-
          Enum.zip([1, true, [], %{}], oracle("ResponseType", [1, true, [], %{}])) do
      refute native["accepted"]
      assert {:error, _} = Response.decode_native("ResponseType", Jason.encode!(value))
      assert {:error, :invalid_model} = Model.decode("ResponseType", value)
    end
  end

  test "fraction and exponent spellings cannot become native integer fields" do
    for type <- ~w(Response ResponseRaw), field <- ~w(status_code error_code) do
      bodies = for token <- ~w(0.0 -0.0 0e0 -0e0 1e0 1.0 1e2), do: ~s({"#{field}":#{token}})

      for {body, native} <- Enum.zip(bodies, oracle_json(type, bodies)) do
        refute native["accepted"]

        assert {:error, %Error{kind: :invalid_response_model}} =
                 Response.decode_native(type, body)
      end
    end
  end

  test "RawMessage retains parsed integer precision while any metadata rounds as float64" do
    values =
      for metadata <- [
            nil,
            true,
            "雪",
            [],
            %{},
            9_007_199_254_740_993,
            %{"nested" => [9_007_199_254_740_993, -9_007_199_254_740_993]}
          ],
          do: %{"metadata" => metadata}

    compare("Response", values)
    compare("ResponseRaw", values)

    body = ~s({"metadata":9007199254740993})

    assert {:ok, %Model{data: %{"metadata" => 9_007_199_254_740_993}}} =
             Response.decode_native("Response", body)

    assert {:ok, %Model{data: %{"metadata" => raw}}} = Response.decode_native("ResponseRaw", body)
    assert is_float(raw) and raw == 9_007_199_254_740_992.0
  end

  test "lossless schema decoding retains nulls, absent and unknown fields separately" do
    for type <- ~w(Response ResponseRaw),
        value <- [nil, %{}, Map.new(@fields, &{&1, nil}), %{"future" => "kept"}] do
      assert {:ok, %Model{data: ^value} = model} = Model.decode(type, value)
      assert Model.encode(model) == value
      refute inspect(model) =~ "kept"
    end

    assert {:error, :invalid_envelope} = Response.decode(~s({"type":"future"}), 200, %{})
    assert {:ok, _} = Response.decode_native("Response", ~s({"type":"future"}))
  end

  test "float64 signed zero is exact; integer-mantissa negative zero rejects on Raw only" do
    compare_json("ResponseRaw", [~s({"metadata":[-0.0,-0.0e0,0.0,"-0","text: -0}"]})])
    compare_json("Response", [~s({"metadata":[-0,0,-0.0]})])

    for body <- [
          ~s({"metadata":-0}),
          ~s({"metadata":[-0]}),
          ~s({"metadata":{"n":-0}}),
          ~s({"metadata":-0e0}),
          ~s({"metadata":-0E+5}),
          ~s({"metadata":-0e-5})
        ] do
      [native] = oracle_json("ResponseRaw", [body])
      assert native["accepted"]

      assert {:error, %Error{kind: :invalid_response_model}} =
               Response.decode_native("ResponseRaw", body)
    end
  end

  test "single ASCII case aliases compare natively; ordered merging and Unicode aliases reject" do
    compare("Response", [%{"TYPE" => "sync", "Status" => "ok", "ERROR_CODE" => 409}])

    cases = [
      ~s({"status":"first","status":null}),
      ~s({"status":"first","Status":"last"}),
      ~s({"metadata":{"a":1},"metadata":{"b":2}}),
      ~s({"metadata":{"a":1,"a":2}}),
      ~s({"ſtatuſ":"folded"}),
      ~s({"雪":"unknown"})
    ]

    for {body, native} <- Enum.zip(cases, oracle_json("Response", cases)) do
      assert native["accepted"]

      assert {:error, %Error{kind: :invalid_response_model}} =
               Response.decode_native("Response", body)
    end
  end

  test "seeded response projections equal native or reject" do
    :rand.seed(:exsss, {17, 31, 101})

    scalars = [
      nil,
      "",
      "sync",
      "future",
      "雪",
      true,
      false,
      0,
      103,
      -1,
      1.5,
      9_007_199_254_740_993,
      9_223_372_036_854_775_808,
      [],
      %{}
    ]

    values =
      for _ <- 1..400 do
        Map.new(@fields, fn field ->
          value = Enum.at(scalars, :rand.uniform(length(scalars)) - 1)
          key = if :rand.uniform(3) == 1, do: String.upcase(field), else: field
          {key, value}
        end)
      end

    for type <- ~w(Response ResponseRaw) do
      for {value, native} <- Enum.zip(values, oracle(type, values)) do
        case Response.decode_native(type, Jason.encode!(value)) do
          {:ok, %Model{data: data}} ->
            assert native["accepted"], inspect(value)
            assert_native(type, data, native)

          {:error, _} ->
            refute native["accepted"], inspect(value)
        end
      end
    end

    valid =
      for _ <- 1..400 do
        %{
          "type" => Enum.at(~w(sync async error future), :rand.uniform(4) - 1),
          "STATUS" => "native #{:rand.uniform(100)} 雪",
          "status_code" => :rand.uniform(2_000) - 1_000,
          "operation" => "/1.0/operations/#{:rand.uniform(100)}",
          "error_code" => :rand.uniform(2_000) - 1_000,
          "error" => if(:rand.uniform(2) == 1, do: nil, else: "native error"),
          "metadata" => %{
            "雪" => Enum.take_random(scalars, 5),
            "number" => :rand.uniform(18_000_000_000_000_000) - 9_000_000_000_000_000
          },
          "unknown" => :rand.uniform(100)
        }
      end

    compare("Response", valid)
    compare("ResponseRaw", valid)
  end

  test "invalid JSON and budget excess reject with redacted diagnostics" do
    for body <- ["", "{", ~s({"metadata":1e999}), <<255>>, %{}, nil, ["{}"]] do
      assert {:error, %Error{kind: :invalid_response_model}} =
               Response.decode_native("Response", body)
    end

    assert {:error, _} = Response.decode_native("Unknown", "{}")
    near_limit = Jason.encode!(%{"metadata" => String.duplicate("x", 1_048_400)})
    compare_json("Response", [near_limit])
    compare_json("ResponseRaw", [near_limit])

    escaped = Jason.encode!(%{"metadata" => String.duplicate("\n", 524_000) <> " text: -0}"})
    compare_json("ResponseRaw", [escaped])

    assert {:error, _} = Response.decode_native("Response", String.duplicate(" ", 1_048_577))

    deep =
      ~s({"metadata":) <> String.duplicate("[", 65) <> "0" <> String.duplicate("]", 65) <> "}"

    [native] = oracle_json("Response", [deep])
    assert native["accepted"]
    assert {:error, error} = Response.decode_native("Response", deep)
    refute inspect(error) =~ "metadata"
  end

  defp compare(type, values), do: compare_json(type, Enum.map(values, &Jason.encode!/1))

  defp compare_json(type, bodies) do
    for {body, native} <- Enum.zip(bodies, oracle_json(type, bodies)) do
      assert native["accepted"]
      assert {:ok, %Model{type: ^type, data: data}} = Response.decode_native(type, body)
      assert_native(type, data, native)
    end
  end

  defp assert_native("ResponseRaw", data, native) do
    expected = Jason.decode!(native["canonical"])
    assert Map.delete(data, "metadata") == Map.delete(expected, "metadata")
    assert float_bits(data["metadata"]) == native["metadata_bits"]
  end

  defp assert_native(_, data, native), do: assert(data == Jason.decode!(native["canonical"]))

  defp float_bits(value) when is_float(value),
    do: %{"float64" => Base.encode16(<<value::float-64>>)}

  defp float_bits(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {key, float_bits(item)} end)

  defp float_bits(value) when is_list(value), do: Enum.map(value, &float_bits/1)
  defp float_bits(value), do: value

  defp oracle(type, values), do: oracle_json(type, Enum.map(values, &Jason.encode!/1))

  defp oracle_json(type, bodies) do
    cases = Enum.map(bodies, &%{type: type, json: &1})
    port = Port.open({:spawn_executable, @driver}, [:binary, :exit_status, :use_stdio])
    Port.command(port, Jason.encode!(%{cases: cases}) <> "\n")
    collect(port, "")
  end

  defp collect(port, data) do
    receive do
      {^port, {:data, bytes}} -> collect(port, data <> bytes)
      {^port, {:exit_status, 0}} -> Jason.decode!(data)["results"]
      {^port, {:exit_status, status}} -> flunk("native driver exited #{status}")
    after
      10_000 ->
        Port.close(port)
        flunk("native response driver timed out")
    end
  end
end
