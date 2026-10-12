defmodule Opsmaru.Incus.ProjectionsReferenceTest do
  use ExUnit.Case, async: false
  alias Opsmaru.Incus.{Error, Model, Projections}
  @driver Path.expand("../../.integration/projections-driver", __DIR__)

  setup_all do
    {out, status} =
      System.cmd("mise", ["exec", "--", "go", "build", "-o", @driver, "./projections"],
        cd: Path.expand("../reference", __DIR__),
        env: [{"GOTOOLCHAIN", "local"}],
        stderr_to_stdout: true
      )

    assert status == 0, out
    :ok
  end

  test "native server filtering preserves fingerprints and exact case-sensitive config heuristic" do
    for config <- [
          nil,
          %{},
          %{
            "auth.token" => "private",
            "auth.key" => "private",
            "auth.cert" => "private",
            "auth.secret" => "private",
            "auth.password" => "private",
            "user.monkey" => "native suffix",
            "user.TOKEN" => "case sensitive",
            "empty.token" => "",
            "plain" => true,
            "count" => 42
          }
        ] do
      body = %{
        "config" => config,
        "api_extensions" => ["a", "a", "b"],
        "api_status" => "stable",
        "api_version" => "1.0",
        "auth" => "trusted",
        "environment" => %{
          "certificate" => "private",
          "certificate_fingerprint" => "keep",
          "server_name" => "native"
        },
        "future" => "ignored"
      }

      compare("filtered", body, Projections.filtered_server(body))

      if is_nil(config) or Enum.all?(config, fn {_, value} -> is_binary(value) end) do
        {:ok, model} = Model.decode("Server", body)
        assert Projections.filtered_server(model) == Projections.filtered_server(body)
        assert model.data == body
      end

      assert {:ok, filtered} = Projections.filtered_server(body)
      refute inspect(filtered) =~ "private"
    end

    compare("filtered", nil, Projections.filtered_server(nil))
  end

  test "logging and network ACL projection preserve native context and timestamp" do
    for type <- ["logging", "network-acl"],
        context <- [nil, %{}, %{"z" => "last", "a" => "first"}] do
      body = event(type, %{"level" => "warn", "message" => "private<&>雪", "context" => context})
      compare("logging", body, Projections.logging_event(body))
    end
  end

  test "lifecycle projection preserves native requestor and generic float64 context" do
    for requestor <- [
          nil,
          %{},
          %{"username" => "host", "protocol" => "tls", "address" => "native:8443"}
        ] do
      body =
        event("lifecycle", %{
          "action" => "instance-started",
          "source" => "/1.0/instances/a",
          "requestor" => requestor,
          "context" => %{"private" => [true, nil, 9_007_199_254_740_993]}
        })

      compare("logging", body, Projections.logging_event(body))
    end
  end

  test "operation projection preserves status, resources, metadata and native zero defaults" do
    for metadata <- [
          %{},
          %{
            "id" => "native",
            "class" => "task",
            "description" => "operation",
            "created_at" => "2026-10-12T12:00:00.123456789Z",
            "updated_at" => "2026-10-12T13:00:00+01:00",
            "status" => "Running",
            "status_code" => 103,
            "resources" => %{"instances" => ["a"]},
            "metadata" => %{"secret" => "private"},
            "may_cancel" => true,
            "err" => "error",
            "location" => "member"
          }
        ] do
      body = event("operation", metadata)
      compare("logging", body, Projections.logging_event(body))
      {:ok, model} = Model.decode("Event", body)
      assert Projections.logging_event(model) == Projections.logging_event(body)
      assert model.data == body
    end
  end

  test "malformed metadata and unsupported event types fail visibly and remain redacted" do
    for body <- [
          event("logging", %{"level" => 7}),
          event("logging", %{"context" => %{"x" => 7}}),
          event("lifecycle", %{"requestor" => "bad"}),
          event("operation", %{"status_code" => "bad"}),
          %{event("logging", %{}) | "timestamp" => "bad"}
        ] do
      refute oracle("logging", body)["ok"]
      assert {:error, %Error{kind: :invalid_metadata}} = Projections.logging_event(body)
    end

    body = event("private-future", %{})
    expected = oracle("logging", body)

    assert {:error, %Error{kind: :unsupported_event_type, message: message} = error} =
             Projections.logging_event(body)

    assert message == expected["error"]
    refute inspect(error) =~ "private"

    for body <- [
          nil,
          [],
          event("logging", nil),
          event("operation", "bad"),
          event("logging", %{"message" => String.duplicate("x", 1_048_577)})
        ] do
      assert {:error, %Error{kind: :invalid_metadata}} = Projections.logging_event(body)
    end

    assert {:error, %Error{kind: :invalid_metadata}} = Projections.filtered_server([])

    assert {:error, %Error{kind: :invalid_metadata}} =
             Projections.filtered_server(%Model{type: "Event", data: %{}})

    assert {:error, %Error{kind: :invalid_metadata}} =
             Projections.logging_event(%Model{type: "Server", data: %{}})

    assert {:error, %Error{kind: :invalid_metadata}} =
             Projections.filtered_server(%{"config" => []})
  end

  defp event(type, metadata),
    do: %{"type" => type, "timestamp" => "2026-10-12T12:00:00.123456789Z", "metadata" => metadata}

  defp compare(action, body, actual) do
    expected = oracle(action, body)
    assert expected["ok"], inspect(expected)
    assert {:ok, %Model{} = model} = actual

    if action == "logging" and body["type"] == "operation" do
      assert Model.encode(model) == expected["value"]
    else
      assert normalize(Model.encode(model)) == normalize(expected["value"])
    end
  end

  # Go map iteration does not specify context-pair order. Compare all exact
  # key/value pairs without erasing duplicate keys in operation contexts.
  defp normalize(%{"Ctx" => context} = value),
    do: %{value | "Ctx" => Enum.chunk_every(context, 2) |> Enum.sort()}

  defp normalize(value), do: value

  defp oracle(action, body) do
    port = Port.open({:spawn_executable, @driver}, [:binary, :exit_status, :use_stdio])
    Port.command(port, Jason.encode!(%{action: action, body: body}) <> "\n")
    collect(port, "")
  end

  defp collect(port, data) do
    receive do
      {^port, {:data, bytes}} ->
        collect(port, data <> bytes)

      {^port, {:exit_status, 0}} ->
        Jason.decode!(data)

      {^port, {:exit_status, status}} ->
        flunk("native projection oracle failed #{status}: #{data}")
    after
      5_000 ->
        Port.close(port)
        flunk("native projection oracle deadline")
    end
  end
end
