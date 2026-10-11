defmodule Opsmaru.Incus.ReferenceWireTest do
  use ExUnit.Case, async: false

  alias Opsmaru.Incus.Connection
  alias Opsmaru.TestSupport.HTTPFixture
  alias Opsmaru.TestSupport.TLSIdentity
  alias Opsmaru.TestSupport.WireComparison

  @fixtures Path.expand("../fixtures/incus/wire.json", __DIR__)
  @driver Path.expand("../../.integration/incus-reference-driver", __DIR__)
  @reference_dir Path.expand("../reference", __DIR__)

  setup_all do
    {module, 0} =
      System.cmd(
        "mise",
        ["exec", "--", "go", "mod", "download", "-json", "github.com/lxc/incus/v7"],
        cd: @reference_dir,
        env: [{"GOTOOLCHAIN", "local"}]
      )

    module = Jason.decode!(module)
    assert module["Version"] == "v7.0.1"
    inventory = Jason.decode!(File.read!("priv/incus/inventory.json"))

    for source <- inventory["sources"] do
      digest = :crypto.hash(:sha256, File.read!(Path.join(module["Dir"], source["path"])))
      assert Base.encode16(digest, case: :lower) == source["sha256"]
    end

    {output, status} =
      System.cmd("mise", ["exec", "--", "go", "build", "-o", @driver, "."],
        cd: @reference_dir,
        stderr_to_stdout: true,
        env: [{"GOTOOLCHAIN", "local"}]
      )

    assert status == 0, output
    :ok
  end

  setup do
    root = Path.join(System.tmp_dir!(), "mc-wire-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "pinned official client agrees with Unix wire fixtures", %{root: root} do
    exercise(:gen_tcp, root)
  end

  test "pinned official client agrees with TLS 1.3 wire fixtures", %{root: root} do
    identity = TLSIdentity.generate(root, "oracle-server", "localhost")

    exercise(:ssl, root,
      certfile: identity.certfile,
      keyfile: identity.keyfile,
      cacertfile: identity.cafile
    )
  end

  test "body, query, native status/error and ETag mismatches are detected" do
    request = %{"body" => %{"value" => 1}, "query" => %{"project" => "one"}, "if_match" => "one"}

    for {key, different} <- [{"body", %{"value" => 2}}, {"query", %{}}, {"if_match", "two"}] do
      assert {:error, [^key]} = WireComparison.compare(request, Map.put(request, key, different))
    end

    result = %{"error_status" => 412, "error" => "conflict", "etag" => "one"}

    for {key, different} <- [{"error_status", 200}, {"error", "success"}, {"etag", "two"}] do
      assert {:error, [^key]} = WireComparison.compare(result, Map.put(result, key, different))
    end

    assert {:error, ["metadata"]} = WireComparison.compare(%{"metadata" => nil}, %{})
    assert {:error, ["error"]} = WireComparison.compare(%{}, %{"error" => "unexpected"})
  end

  defp envelope(response) do
    Map.new([:type, :status, :status_code, :operation, :error_code, :error, :metadata], fn key ->
      {Atom.to_string(key), Map.fetch!(response, key)}
    end)
  end

  defp exercise(transport, root, tls_opts \\ []) do
    fixtures = Jason.decode!(File.read!(@fixtures))
    pin = Jason.decode!(File.read!("priv/incus/reference.json"))
    assert fixtures["reference_revision"] == pin["revision"]

    for {fixture, index} <- Enum.with_index(fixtures["cases"]) do
      reply = fixture["reply"]
      response = %{status: reply["status"], headers: reply["headers"], body: reply["body"]}
      handler = fn _request -> response end

      pid =
        start_supervised!(
          {HTTPFixture,
           [transport: transport, path: Path.join(root, "socket-#{index}"), handler: handler] ++
             tls_opts},
          id: {transport, index}
        )

      endpoint = HTTPFixture.endpoint(pid)

      input =
        Map.merge(fixture["input"], Map.new(endpoint, fn {k, v} -> {Atom.to_string(k), v} end))

      input =
        if transport == :ssl,
          do: Map.put(input, "server_cert", File.read!(tls_opts[:certfile])),
          else: input

      input_path = Path.join(root, "input-#{index}.json")
      File.write!(input_path, Jason.encode!(input))
      File.chmod!(input_path, 0o600)
      {output, status} = System.cmd(@driver, [input_path], stderr_to_stdout: true)
      assert status == 0, output
      assert :ok == WireComparison.compare(fixture["result"], Jason.decode!(output))
      assert [request] = HTTPFixture.requests(pid)
      assert :ok == WireComparison.compare(fixture["request"], WireComparison.request(request))
      stop_supervised!({transport, index})

      pid =
        start_supervised!(
          {HTTPFixture,
           [
             transport: transport,
             path: Path.join(root, "elixir-socket-#{index}"),
             handler: handler
           ] ++ tls_opts},
          id: {transport, index}
        )

      endpoint = HTTPFixture.endpoint(pid)
      context = Opsmaru.Context.new!(owner: :fixture, identity: :verified, ready?: fn -> true end)

      connection =
        if transport == :gen_tcp do
          Connection.unix!(endpoint.socket, owner: :fixture)
        else
          Connection.https!(endpoint.url,
            owner: :fixture,
            tls: [
              cacertfile: tls_opts[:cacertfile],
              certfile: tls_opts[:certfile],
              keyfile: tls_opts[:keyfile]
            ]
          )
        end

      opts = [body: fixture["input"]["body"], etag: fixture["input"]["etag"]]

      result =
        Opsmaru.Incus.raw_query(
          connection,
          context,
          fixture["input"]["method"],
          fixture["input"]["path"],
          opts
        )

      actual =
        case result do
          {:ok, response} ->
            %{"response" => envelope(response), "etag" => response.etag}

          {:error, %Opsmaru.Incus.Error{kind: :native} = error} ->
            %{
              "response" => envelope(error.response),
              "etag" => "",
              "error" => error.message,
              "error_status" => error.error_code
            }
        end

      assert :ok == WireComparison.compare(fixture["result"], actual)
      assert [request] = HTTPFixture.requests(pid)
      assert :ok == WireComparison.compare(fixture["request"], WireComparison.request(request))
      stop_supervised!({transport, index})
    end
  end
end
