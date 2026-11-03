defmodule Opsmaru.TestSupport.OperationsFixture do
  @moduledoc """
  Scripted fake Incus for operation tests over Unix or mutual HTTPS.

  `routes` maps a request to a response (or `:next` to fall through to the
  discovery default). Captured requests are authoritative: a denial test
  asserts the list is empty. No real backend, VM or Swift socket is touched.
  """
  import ExUnit.Callbacks, only: [start_supervised!: 2]
  alias Opsmaru.Incus.{Connection, Context}
  alias Opsmaru.TestSupport.{HTTPFixture, TLSIdentity}

  @extensions ~w(storage network projects container_exec_user_group_cwd)

  def root do
    root = Path.join(System.tmp_dir!(), "op-ops-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    root
  end

  @doc "Start a fixture; returns `%{connection, context, fixture}`."
  def start(root, transport, routes, opts \\ []) do
    extensions = Keyword.get(opts, :extensions, @extensions)

    handler = fn request ->
      case routes.(request) do
        :next -> default(request, extensions)
        response -> response
      end
    end

    identity =
      if transport == :ssl,
        do: TLSIdentity.generate(root, "ops-#{System.unique_integer([:positive])}", "localhost")

    tls =
      if identity,
        do: [
          certfile: identity.certfile,
          keyfile: identity.keyfile,
          peer_options: [
            verify: :verify_peer,
            fail_if_no_peer_cert: true,
            cacertfile: identity.cafile
          ]
        ],
        else: []

    fixture =
      start_supervised!(
        {HTTPFixture,
         [
           transport: transport,
           path: Path.join(root, "s-#{System.unique_integer([:positive])}"),
           handler: handler
         ] ++ tls},
        id: make_ref()
      )

    endpoint = HTTPFixture.endpoint(fixture)

    connection_opts =
      [owner: :fixture, timeout: Keyword.get(opts, :timeout, 15_000)] ++
        Keyword.get(opts, :connection, [])

    connection =
      if identity,
        do:
          Connection.https!(
            endpoint.url,
            connection_opts ++
              [
                tls: [
                  cacertfile: identity.cafile,
                  certfile: identity.certfile,
                  keyfile: identity.keyfile
                ]
              ]
          ),
        else: Connection.unix!(endpoint.socket, connection_opts)

    %{
      connection: connection,
      context: Context.new!(owner: :fixture, identity: :verified, ready?: fn -> true end),
      fixture: fixture
    }
  end

  def requests(%{fixture: fixture}), do: HTTPFixture.requests(fixture)

  @doc "Requests other than discovery."
  def backend_requests(fixture),
    do: Enum.reject(requests(fixture), &(URI.parse(&1.target).path == "/1.0"))

  defp default(request, extensions) do
    if URI.parse(request.target).path == "/1.0",
      do:
        sync(%{
          "api_version" => "1.0",
          "api_extensions" => extensions,
          "api_status" => "stable",
          "auth" => "trusted",
          "environment" => %{"server_name" => "fixture", "server_version" => "7.0.1"}
        }),
      else: native_error(404, "not found")
  end

  def sync(metadata, headers \\ %{}),
    do: %{
      status: 200,
      headers: headers,
      body: %{type: "sync", status: "Success", status_code: 200, metadata: metadata}
    }

  def native_error(status, message),
    do: %{
      status: status,
      body: %{type: "error", error_code: status, error: message, metadata: nil}
    }

  def operation(id, status_code, extra \\ %{}) do
    Map.merge(
      %{
        "id" => id,
        "class" => "task",
        "description" => "fixture",
        "status" => status(status_code),
        "status_code" => status_code,
        "resources" => %{},
        "metadata" => %{},
        "may_cancel" => false,
        "err" => if(status_code >= 400, do: "boom", else: ""),
        "location" => "none"
      },
      extra
    )
  end

  def accepted(id, status_code \\ 103, extra \\ %{}),
    do: %{
      status: 202,
      body: %{
        type: "async",
        status: "Operation created",
        status_code: 100,
        operation: "/1.0/operations/" <> id,
        metadata: operation(id, status_code, extra)
      }
    }

  defp status(200), do: "Success"
  defp status(103), do: "Running"
  defp status(401), do: "Cancelled"
  defp status(code) when code >= 400, do: "Failure"
  defp status(_), do: "Pending"

  def path(request), do: URI.parse(request.target).path
  def query(request), do: URI.decode_query(URI.parse(request.target).query || "")
end

defmodule Opsmaru.TestSupport.OperationsHost do
  @moduledoc """
  Test host binding driven entirely by the caller map:

    * `:binding` - `{connection, context}`, a client, or a function;
    * `:authorize` - `fn operation, input -> :ok | {:error, term} end`;
    * `:remotes` - image remote name => source map;
    * `:allow_restricted` - boolean.

  Every callback reports to `:test_pid` so tests can assert call order.
  """
  @behaviour Opsmaru.Incus.Operations.Host

  @impl true
  def binding(caller, operation) do
    notify(caller, {:binding, operation})

    case Map.fetch!(caller, :binding) do
      fun when is_function(fun, 1) -> fun.(operation)
      {connection, context} -> {:ok, connection, context}
      client -> {:ok, client}
    end
  end

  @impl true
  def authorize(caller, operation, input) do
    notify(caller, {:authorize, operation, input})
    Map.get(caller, :authorize, fn _, _ -> :ok end).(operation, input)
  end

  @impl true
  def image_remote(caller, name) do
    notify(caller, {:image_remote, name})

    case Map.fetch(Map.get(caller, :remotes, %{}), name) do
      {:ok, source} -> {:ok, source}
      :error -> {:error, :unknown_remote}
    end
  end

  @impl true
  def allow_restricted?(caller, operation, items) do
    notify(caller, {:allow_restricted, operation, items})
    Map.get(caller, :allow_restricted, false)
  end

  defp notify(%{test_pid: pid}, message), do: send(pid, {:host, message})
  defp notify(_, _), do: :ok
end
