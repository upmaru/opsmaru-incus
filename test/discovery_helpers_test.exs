defmodule Opsmaru.Incus.DiscoveryHelpersTest do
  use ExUnit.Case, async: false
  alias Opsmaru.Incus
  alias Opsmaru.Incus.{Connection, Context, Discovery, Error, Server}
  alias Opsmaru.TestSupport.{HTTPFixture, TLSIdentity}
  @driver Path.expand("../.integration/discovery-driver", __DIR__)
  setup_all do
    {out, status} =
      System.cmd("mise", ["exec", "--", "go", "build", "-o", @driver, "./discovery"],
        cd: Path.expand("reference", __DIR__),
        env: [{"GOTOOLCHAIN", "local"}],
        stderr_to_stdout: true
      )

    assert status == 0, out
    :ok
  end

  setup do
    root = Path.join(System.tmp_dir!(), "op-d-info-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  for transport <- [:unix, :https] do
    test "#{transport} native connection information and authenticated header requirement stay explicit",
         %{root: root} do
      compare(root, unquote(transport))
    end
  end

  defp compare(root, transport) do
    identity = TLSIdentity.generate(root, "identity", "localhost")
    certificate = File.read!(identity.certfile)

    environment = %{
      "server_name" => "native-member",
      "certificate" => certificate,
      "server_clustered" => true,
      "server" => "incus-agent",
      "addresses" => ["advertised.example:8443", ":8443", "[::1]:8443", "advertised.example:8443"]
    }

    opts =
      if transport == :unix,
        do: [transport: :gen_tcp, path: Path.join(root, "s")],
        else: [transport: :ssl, certfile: identity.certfile, keyfile: identity.keyfile]

    fixture =
      start_supervised!(
        {HTTPFixture,
         opts ++
           [
             handler: fn _ ->
               %{
                 status: 200,
                 body: %{
                   type: "sync",
                   metadata: %{
                     api_version: "1.0",
                     auth: "trusted",
                     api_extensions: [],
                     environment: environment
                   }
                 }
               }
             end
           ]}
      )

    endpoint = HTTPFixture.endpoint(fixture)

    connection =
      if transport == :unix,
        do: Connection.unix!(endpoint.socket, owner: :fixture),
        else:
          Connection.https!(endpoint.url,
            owner: :fixture,
            tls: [
              cacertfile: identity.cafile,
              certfile: identity.certfile,
              keyfile: identity.keyfile
            ]
          )

    client = %Incus{
      connection: connection,
      context: Context.new!(owner: :fixture, identity: :verified, ready?: fn -> true end),
      server: %Server{auth: "trusted", api_extensions: [], environment: environment}
    }

    for {project, member, flag} <- [
          {nil, nil, false},
          {nil, "selected", true},
          {"fixture", nil, true},
          {"fixture", "selected", false}
        ] do
      client = %{client | connection: %{connection | project: project, member: member}}

      expected =
        oracle(
          Map.merge(endpoint, %{
            certificate: certificate,
            project: project || "",
            member: member || "",
            authenticated: flag
          })
        )

      native_request = HTTPFixture.requests(fixture) |> List.last()
      count = length(HTTPFixture.requests(fixture))
      assert {:ok, info} = Discovery.connection_info(client)
      assert info.certificate == expected["info"]["Certificate"]
      assert info.url == expected["info"]["URL"]
      assert info.socket_path == expected["info"]["SocketPath"]
      assert info.project == expected["info"]["Project"]
      assert info.target == expected["info"]["Target"]
      assert info.addresses == expected["info"]["Addresses"]
      assert info.protocol == expected["info"]["Protocol"]
      assert {:ok, clustered} = Discovery.clustered?(client)
      assert {:ok, agent} = Discovery.agent?(client)
      assert clustered == expected["clustered"]
      assert agent == expected["agent"]
      assert {:ok, changed} = Discovery.require_authenticated(client, flag)
      assert length(HTTPFixture.requests(fixture)) == count
      assert {:ok, _} = Incus.call(changed, "GetProfile", %{"name" => "default"})
      actual = HTTPFixture.requests(fixture) |> List.last()
      assert actual.target == native_request.target

      assert actual.headers["x-incus-authenticated"] ==
               native_request.headers["x-incus-authenticated"]

      refute client.connection.require_authenticated
      refute inspect(info) =~ "advertised.example"
      refute inspect(info) =~ "CERTIFICATE"
    end
  end

  test "discovery helpers perform no I/O and reject unready/binding failures without exposing metadata",
       %{root: root} do
    connection = Connection.unix!(Path.join(root, "never-opened"), owner: :fixture)

    client = %Incus{
      connection: connection,
      context: Context.new!(owner: :fixture, identity: :verified, ready?: fn -> false end),
      server: %Server{environment: %{}}
    }

    for helper <- [
          &Discovery.connection_info/1,
          &Discovery.clustered?/1,
          &Discovery.agent?/1,
          &Discovery.require_authenticated/1
        ] do
      assert {:error, %Error{}} = helper.(client)
    end

    ready = %{client | context: %{client.context | ready?: fn -> true end}}

    assert {:error, %Error{kind: :invalid_arguments}} =
             Discovery.require_authenticated(ready, "true")

    assert {:ok, false} = Discovery.clustered?(ready)
    assert {:ok, false} = Discovery.agent?(ready)
    assert {:ok, info} = Discovery.connection_info(ready)
    assert info.addresses == []
    assert info.target == ""
    invalid = %{ready | server: %Server{environment: %{"addresses" => [123]}}}
    assert {:error, %Error{kind: :invalid_server}} = Discovery.connection_info(invalid)

    overflow = %{
      ready
      | server: %Server{
          environment: %{"addresses" => List.duplicate("advertised.example:8443", 1025)}
        }
    }

    assert {:error, %Error{kind: :response_limit}} = Discovery.connection_info(overflow)
    assert File.ls!(root) == []
  end

  defp oracle(input) do
    port = Port.open({:spawn_executable, @driver}, [:binary, :exit_status, :use_stdio])
    Port.command(port, Jason.encode!(input) <> "\n")
    collect(port, "")
  end

  defp collect(port, out) do
    receive do
      {^port, {:data, bytes}} -> collect(port, out <> bytes)
      {^port, {:exit_status, 0}} -> Jason.decode!(out)
      {^port, {:exit_status, status}} -> flunk("native discovery failed #{status}: #{out}")
    after
      10_000 ->
        Port.close(port)
        flunk("native discovery deadline")
    end
  end
end
