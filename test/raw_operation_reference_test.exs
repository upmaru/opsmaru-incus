defmodule Opsmaru.Incus.RawOperationReferenceTest do
  use ExUnit.Case, async: false
  alias Opsmaru.{Context, Incus}
  alias Opsmaru.Incus.{Connection, Error, Operation, Server}
  alias Opsmaru.TestSupport.HTTPFixture
  @driver Path.expand("../../.integration/raw-operation-driver", __DIR__)

  setup_all do
    {out, status} =
      System.cmd("mise", ["exec", "--", "go", "build", "-o", @driver, "."],
        cd: Path.expand("../reference", __DIR__),
        env: [{"GOTOOLCHAIN", "local"}],
        stderr_to_stdout: true
      )

    assert status == 0, out
    :ok
  end

  setup do
    root = Path.join(System.tmp_dir!(), "op-raw-op-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "official RawOperation agrees on native request, ETag and acceptance without implicit wait",
       %{root: root} do
    {client, fixture} = backend(root, :accepted)
    input = Path.join(root, "input.json")
    body = %{"native" => "configuration"}

    File.write!(
      input,
      Jason.encode!(%{
        socket: client.connection.address,
        project: "fixture",
        target: "member",
        action: "RawOperation",
        args: ["PATCH", "/instances/native?native=value", body, "\"before\""]
      })
    )

    {out, status} = System.cmd(@driver, [input], stderr_to_stdout: true)
    assert status == 0, out
    result = Jason.decode!(out)
    refute result["error"], out
    assert Enum.at(result["outputs"], 0)["id"] == "native"
    assert Enum.at(result["outputs"], 1) == "\"after\""
    expected = HTTPFixture.requests(fixture) |> List.last()

    assert {:ok, op} =
             Operation.raw(client, "PATCH", "/1.0/instances/native?native=value",
               body: body,
               etag: "\"before\""
             )

    actual = HTTPFixture.requests(fixture) |> List.last()
    assert actual.method == expected.method
    assert actual.target == expected.target
    assert actual.headers["if-match"] == expected.headers["if-match"]
    assert Jason.decode!(actual.body) == Jason.decode!(expected.body)
    assert op.response.etag == "\"after\""
    assert op.url == "/1.0/operations/native"
    refute Operation.completed?(op)
    assert op.client.connection == client.connection
    refute Enum.any?(HTTPFixture.requests(fixture), &String.contains?(&1.target, "/operations/"))
  end

  test "raw operation retains explicit native rejection and never retries a lost mutation", %{
    root: root
  } do
    {client, fixture} = backend(root, :rejected)

    assert {:error,
            %Error{
              kind: :native,
              error_code: 777,
              http_status: 409,
              operation: "/1.0/operations/known"
            }} = Operation.raw(client, "POST", "/1.0/instances", body: %{})

    assert length(HTTPFixture.requests(fixture)) == 1
    {lost, fixture} = backend(root, :lost)

    assert {:error, %Error{kind: :uncertain}} =
             Operation.raw(lost, "POST", "/1.0/instances", body: %{})

    assert length(HTTPFixture.requests(fixture)) == 1
  end

  test "raw operation cannot substitute an external origin or bind a synchronous response", %{
    root: root
  } do
    {client, fixture} = backend(root, :sync)

    assert {:error, %Error{kind: :invalid_path}} =
             Operation.raw(client, "GET", "https://other.example/1.0/instances")

    assert HTTPFixture.requests(fixture) == []

    assert {:error, %Error{kind: :invalid_operation_binding}} =
             Operation.raw(client, "POST", "/1.0/instances", body: %{})

    assert length(HTTPFixture.requests(fixture)) == 1
  end

  defp backend(root, outcome) do
    fixture =
      start_supervised!(
        {HTTPFixture,
         transport: :gen_tcp,
         path: Path.join(root, Atom.to_string(outcome) <> ".sock"),
         handler: fn req ->
           if URI.parse(req.target).path == "/1.0" do
             %{
               status: 200,
               body: %{type: "sync", metadata: %{api_version: "1.0", api_extensions: []}}
             }
           else
             case outcome do
               :accepted ->
                 %{
                   status: 202,
                   headers: %{"etag" => "\"after\""},
                   body: %{
                     type: "async",
                     operation: "/1.0/operations/native",
                     metadata: %{id: "native", status_code: 103}
                   }
                 }

               :rejected ->
                 %{
                   status: 409,
                   body: %{
                     type: "error",
                     error_code: 777,
                     error: "native",
                     operation: "/1.0/operations/known"
                   }
                 }

               :lost ->
                 %{raw: ""}

               :sync ->
                 %{status: 200, body: %{type: "sync", metadata: %{}}}
             end
           end
         end},
        id: make_ref()
      )

    client = %Incus{
      connection:
        Connection.unix!(HTTPFixture.endpoint(fixture).socket,
          owner: :fixture,
          project: "fixture",
          member: "member"
        ),
      context: Context.new!(owner: :fixture, identity: :verified, ready?: fn -> true end),
      server: %Server{api_extensions: []}
    }

    {client, fixture}
  end
end
