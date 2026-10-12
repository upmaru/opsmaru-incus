defmodule Opsmaru.Incus.StatusErrorReferenceTest do
  use ExUnit.Case, async: false

  alias Opsmaru.Incus.{Error, StatusError}

  @driver Path.expand("../../.integration/status-error-driver", __DIR__)

  setup_all do
    {out, status} =
      System.cmd("mise", ["exec", "--", "go", "build", "-o", @driver, "./statuserror"],
        cd: Path.expand("../reference", __DIR__),
        env: [{"GOTOOLCHAIN", "local"}],
        stderr_to_stdout: true
      )

    assert status == 0, out
    :ok
  end

  test "Error uses the exact native status text for every status with an empty message" do
    statuses =
      Enum.to_list(0..999) ++
        [9_223_372_036_854_775_807, -9_223_372_036_854_775_808, -42, -1, 0]

    compare_statuses(statuses, "")
  end

  test "non-empty messages are verbatim, including Unicode, control bytes and literal %" do
    messages = [
      "100%",
      "literal %v %d %s stay literal",
      "unicode ☃ 雪",
      <<0, 7, 27, 127>>,
      "line1\nline2\ttabbed\rtrailing",
      "  spaced  "
    ]

    Enum.each(messages, fn message -> compare_statuses([404, 200, 0], message) end)
  end

  test "Match and Check agree with native codes, including none, matches and duplicates" do
    cases = [
      %{"status" => 404, "message" => "missing", "codes" => []},
      %{"status" => 404, "message" => "missing", "codes" => [404]},
      %{"status" => 404, "message" => "missing", "codes" => [500, 404, 404, 404]},
      %{"status" => 404, "message" => "missing", "codes" => [500, 503]},
      %{"status" => 0, "message" => "", "codes" => [0]},
      %{"status" => 0, "message" => "", "codes" => [404]},
      %{"status" => -42, "message" => "negative", "codes" => [-42, -42]},
      %{
        "status" => 9_223_372_036_854_775_807,
        "message" => "max",
        "codes" => [1, 9_223_372_036_854_775_807]
      }
    ]

    for {case, result} <- Enum.zip(cases, oracle(cases)) do
      {:ok, term} = StatusError.new(case["status"], case["message"])
      [match_status, found] = result["match"]
      assert {^match_status, ^found} = StatusError.match(term, case["codes"])
      assert StatusError.check(term, case["codes"]) == found
    end

    {:ok, term} = StatusError.new(503, "down")
    assert {503, true} = StatusError.match(term)
    assert StatusError.check(term)
  end

  test "the native literal zero value matches Elixir's default struct" do
    cases = [
      %{"zero" => true, "codes" => []},
      %{"zero" => true, "codes" => [0]},
      %{"zero" => true, "codes" => [404]}
    ]

    for {case, result} <- Enum.zip(cases, oracle(cases)) do
      term = %StatusError{}
      assert StatusError.error(term) == result["error"]
      assert StatusError.status(term) == result["status"]
      [match_status, found] = result["match"]
      assert {^match_status, ^found} = StatusError.match(term, case["codes"])
      assert StatusError.check(term, case["codes"]) == found
    end
  end

  test "non-StatusError terms never match, on the native side or in Elixir" do
    [result] = oracle([%{"plain" => true, "message" => "", "codes" => [404]}])
    assert result["error"] == "not a status error"
    assert result["status"] == nil
    assert result["match"] == [-1, false]
    assert result["check"] == false

    terms = [
      %Error{kind: :invalid_input},
      "not a status error",
      :not_a_status_error,
      404,
      {:error, %Error{kind: :invalid_input}},
      %{"status" => 404, "message" => "not a struct"},
      nil
    ]

    for term <- terms do
      assert {-1, false} = StatusError.match(term, [404])
      refute StatusError.check(term, [404])
    end
  end

  test "invalid construction input is rejected without raising" do
    for status <- [nil, :ok, "404", 4.5, 9_223_372_036_854_775_808, -9_223_372_036_854_775_809] do
      assert {:error, %Error{kind: :invalid_input}} = StatusError.new(status, "x")
    end

    for message <- [nil, :x, 404, String.duplicate("a", 65_537)] do
      assert {:error, %Error{kind: :invalid_input}} = StatusError.new(404, message)
    end

    assert {:ok, %StatusError{status: 404, message: ""}} = StatusError.new(404, "")

    assert {:ok, %StatusError{status: 9_223_372_036_854_775_807, message: msg}} =
             StatusError.new(9_223_372_036_854_775_807, String.duplicate("a", 65_536))

    assert byte_size(msg) == 65_536
  end

  test "match and check reject invalid code lists without raising" do
    {:ok, term} = StatusError.new(404, "missing")

    for codes <- [
          nil,
          :ok,
          404,
          "404",
          [nil],
          [:ok],
          ["404"],
          [9_223_372_036_854_775_808],
          [404 | :tail],
          List.duplicate(404, 1_025)
        ] do
      assert {:error, %Error{kind: :invalid_input}} = StatusError.match(term, codes)
      assert {:error, %Error{kind: :invalid_input}} = StatusError.check(term, codes)
    end

    assert {404, true} = StatusError.match(term, List.duplicate(404, 1_024))
    assert StatusError.check(term, [])
  end

  test "Inspect redacts the message" do
    {:ok, term} = StatusError.new(404, "top secret message")
    rendering = inspect(term)
    refute rendering =~ "top secret message"
    assert rendering =~ "redacted"
    assert rendering =~ "status: 404"
  end

  defp compare_statuses(statuses, message) do
    cases = Enum.map(statuses, fn status -> %{"status" => status, "message" => message} end)

    for {case, result} <- Enum.zip(cases, oracle(cases)) do
      {:ok, term} = StatusError.new(case["status"], message)
      assert StatusError.error(term) == result["error"]
      assert StatusError.status(term) == result["status"]
    end
  end

  defp oracle(cases) do
    port = Port.open({:spawn_executable, @driver}, [:binary, :exit_status, :use_stdio])
    Port.command(port, Jason.encode!(%{cases: cases}) <> "\n")
    collect(port, "")
  end

  defp collect(port, data) do
    receive do
      {^port, {:data, bytes}} ->
        collect(port, data <> bytes)

      {^port, {:exit_status, 0}} ->
        Jason.decode!(data)["results"]

      {^port, {:exit_status, status}} ->
        flunk("native status-error oracle failed #{status}: #{data}")
    after
      10_000 ->
        Port.close(port)
        flunk("native status-error oracle deadline")
    end
  end
end
