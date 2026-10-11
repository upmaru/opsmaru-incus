defmodule Opsmaru.Incus.MetadataHelpersReferenceTest do
  use ExUnit.Case, async: false
  alias Opsmaru.Incus.{Error, Model, Operation, Response, Tokens}
  @driver Path.expand("../../.integration/metadata-helpers-driver", __DIR__)

  setup_all do
    {out, status} =
      System.cmd("mise", ["exec", "--", "go", "build", "-o", @driver, "./metadatahelpers"],
        cd: Path.expand("../reference", __DIR__),
        env: [{"GOTOOLCHAIN", "local"}],
        stderr_to_stdout: true
      )

    assert status == 0, out
    :ok
  end

  test "native map and string-slice extraction distinguishes null, empty and malformed values" do
    for body <- [nil, %{}, %{"private" => true}, [], ["native", nil, "雪"], [7], "bad"] do
      compare("map", body, Response.metadata_as_map(%Response{metadata: body}))
      compare("strings", body, Response.metadata_as_string_slice(%Response{metadata: body}))
    end
  end

  test "operation projection preserves native defaults, populated fields and errors" do
    for body <- [
          nil,
          %{},
          %{
            "id" => "native",
            "metadata" => %{
              "secret" => "private",
              "number" => 9_007_199_254_740_993,
              "nested" => [%{"n" => 9_007_199_254_740_993}]
            },
            "resources" => %{"instances" => ["/1.0/instances/a"]},
            "status_code" => 103,
            "may_cancel" => true,
            "created_at" => "2026-10-11T12:00:00.123456789Z",
            "updated_at" => "2026-10-11T12:00:00.120000000+01:00",
            "future" => "ignored"
          },
          %{"status_code" => "bad"},
          %{"created_at" => "bad"},
          []
        ] do
      response = %Response{metadata: body}
      compare("operation", body, Response.metadata_as_operation(response))
      assert response.metadata == body
    end
  end

  test "generic struct extraction materializes native typed defaults without changing lossless models" do
    for body <- [nil, %{}, %{"name" => "native", "status_code" => 103, "ephemeral" => true}] do
      compare("instance", body, Response.metadata_as_model(%Response{metadata: body}, "Instance"))
    end

    assert {:error, %Error{kind: :invalid_metadata}} =
             Response.metadata_as_model(%Response{metadata: %{}}, "Unknown")
  end

  for action <- ["certificate", "cluster"] do
    test "#{action} token conversion and exact base64 agree with unchanged native helpers" do
      action = unquote(action)

      for expiry <- [nil, 7, "2026-10-11T12:00:00.123456789Z", "bad"],
          addresses <- [[], ["127.0.0.1:8443", "unapproved.example:8443"], nil, [7]] do
        metadata = %{
          "request" => %{"name" => "private<&>雪\u2028"},
          "serverName" => "private<&>雪\u2029",
          "secret" => "secret<&>\\u003C\u001f",
          "fingerprint" => "native-fingerprint",
          "addresses" => addresses,
          "expiresAt" => expiry
        }

        body = %{"metadata" => metadata}
        expected = oracle(action, body)
        {:ok, operation} = Model.decode("Operation", body)

        result =
          if action == "certificate",
            do: Tokens.certificate(operation),
            else: Tokens.cluster(operation)

        if expected["ok"] do
          assert {:ok, token} = result
          assert Model.encode(token) == expected["value"]["token"]
          assert {:ok, encoded} = Tokens.encode(token)
          assert encoded == expected["value"]["encoded"]
          refute inspect(token) =~ "secret"
          assert operation.data == body
        else
          assert {:error, %Error{kind: :invalid_token}} = result
        end
      end
    end
  end

  test "token helpers reject malformed metadata, wrong model and byte-budget abuse without exposing secrets" do
    for metadata <- [
          nil,
          %{},
          %{"request" => %{"name" => 7}},
          %{"secret" => String.duplicate("x", 1_048_577)}
        ] do
      assert {:error, %Error{kind: :invalid_token}} =
               Tokens.certificate(%Model{type: "Operation", data: %{"metadata" => metadata}})
    end

    assert {:error, %Error{kind: :invalid_token}} = Tokens.encode(nil)
    assert {:error, %Error{kind: :invalid_token}} = Tokens.cluster(nil)

    assert {:error, %Error{kind: :invalid_metadata}} =
             Response.metadata_as_operation(%Response{
               metadata: %{"description" => String.duplicate("x", 1_048_577)}
             })
  end

  test "map projection preserves native float64 precision, typed model data and its budget" do
    data = %{
      "number" => 9_007_199_254_740_993,
      "nested" => [%{"number" => 9_007_199_254_740_993}]
    }

    compare("map", data, Response.metadata_as_map(%Response{metadata: data}))

    assert {:ok, %{}} =
             Response.metadata_as_map(%Response{metadata: %Model{type: "Operation", data: nil}})

    assert {:error, %Error{kind: :invalid_metadata}} =
             Response.metadata_as_map(%Response{metadata: %{bad: self()}})

    assert {:error, %Error{kind: :invalid_metadata}} =
             Response.metadata_as_map(%Response{
               metadata: %{"private" => String.duplicate("x", 1_048_577)}
             })
  end

  test "token conversion failure retains an already accepted operation and originating response" do
    response = %Response{
      type: "async",
      operation: "/1.0/operations/token",
      identity: :host,
      metadata: %{"id" => "token", "metadata" => %{"secret" => "private-missing-fields"}}
    }

    operation = %Operation{client: nil, url: response.operation, response: response}

    for result <- [Tokens.certificate(operation), Tokens.cluster(operation)] do
      assert {:error,
              %Error{
                kind: :invalid_token,
                response: ^response,
                operation: "/1.0/operations/token"
              } = error} = result

      refute inspect(error) =~ "private-missing-fields"
    end
  end

  test "string-slice extraction enforces its documented byte budget before copying" do
    response = %Response{metadata: [String.duplicate("x", 1_048_577)]}

    result =
      case Response.metadata_as_string_slice(response) do
        {:error, %Error{kind: kind}} -> kind
        _ -> :accepted
      end

    assert result == :invalid_metadata
  end

  defp compare(action, body, actual) do
    expected = oracle(action, body)

    if expected["ok"] do
      assert {:ok, result} = actual
      assert Model.encode(result) == expected["value"]
    else
      assert {:error, %Error{kind: :invalid_metadata}} = actual
    end
  end

  defp oracle(action, body) do
    port = Port.open({:spawn_executable, @driver}, [:binary, :exit_status, :use_stdio])
    Port.command(port, Jason.encode!(%{action: action, body: body}) <> "\n")
    collect(port, "")
  end

  defp collect(port, data) do
    receive do
      {^port, {:data, bytes}} -> collect(port, data <> bytes)
      {^port, {:exit_status, 0}} -> Jason.decode!(data)
      {^port, {:exit_status, status}} -> flunk("native metadata oracle failed #{status}: #{data}")
    after
      5_000 ->
        Port.close(port)
        flunk("native metadata oracle deadline")
    end
  end
end
