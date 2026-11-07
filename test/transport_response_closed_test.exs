defmodule Opsmaru.Incus.TransportResponseClosedTest do
  use ExUnit.Case, async: true
  alias Opsmaru.Incus
  alias Opsmaru.Incus.{Connection, Context, Error, HTTP, Transport}
  alias Opsmaru.TestSupport.HTTPFixture

  setup do
    root = Path.join(System.tmp_dir!(), "closed-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    %{
      root: root,
      binding: Context.new!(owner: :closed_fixture, identity: :verified, ready?: fn -> true end)
    }
  end

  test "only an exact pre-observation Mint close with an empty event batch is recoverable" do
    acc = %{status: nil, headers: %{}, raw_headers: nil, body: [], bytes: 0, header_bytes: 0}
    error = %Mint.TransportError{reason: :closed}
    ref = make_ref()
    assert Transport.response_error_kind(error, [], acc) == :response_closed

    for event <- [
          {:status, ref, 403},
          {:status, ref, 404},
          {:headers, ref, []},
          {:data, ref, ""},
          {:done, ref},
          {:error, ref, :closed},
          {:unknown, ref},
          {:status, make_ref(), 200}
        ] do
      assert Transport.response_error_kind(error, [event], acc) == :response
    end

    for previous <- [
          %{acc | status: 403},
          %{acc | status: 404},
          %{acc | headers: %{"x" => "v"}},
          %{acc | raw_headers: []},
          %{acc | raw_headers: [{"x", "v"}]},
          %{acc | body: ["x"], bytes: 1},
          %{acc | header_bytes: 1}
        ] do
      assert Transport.response_error_kind(error, [], previous) == :response
    end

    assert Transport.response_error_kind(%Mint.HTTPError{reason: :invalid_status_line}, [], acc) ==
             :response

    assert Transport.response_error_kind(%Mint.TransportError{reason: :econnreset}, [], acc) ==
             :response

    assert Transport.response_error_kind(%Mint.TransportError{reason: :timeout}, [], acc) ==
             :deadline
  end

  test "actual early close differs from malformed HTTP and truncated native statuses", context do
    for {response, expected} <- [
          {%{raw: ""}, :response_closed},
          {%{raw: "HTTP/1."}, :response_closed},
          {%{raw: "garbage\r\n\r\n"}, :response},
          {%{raw: "HTTP/1.1 403 Forbidden\r\nContent-Length: 20\r\n\r\nshort"}, :response},
          {%{raw: "HTTP/1.1 404 Not Found\r\nContent-Length: 20\r\n\r\nshort"}, :response},
          {%{
             wire_chunks: [
               {0, "HTTP/1.1 403 Forbidden\r\nContent-Length: 20\r\n\r\n"},
               {5, "short"}
             ]
           }, :response},
          {%{
             wire_chunks: [
               {0, "HTTP/1.1 404 Not Found\r\nContent-Length: 20\r\n\r\n"},
               {5, "short"}
             ]
           }, :response}
        ] do
      {fixture, connection} = backend(context, response)

      assert {:error, %Error{kind: ^expected}} =
               Incus.raw_query(connection, context.binding, "GET", "/1.0", [])

      assert [%{method: "GET"}] = HTTPFixture.requests(fixture)
    end

    observer = self()

    {fixture, connection} =
      backend(context, %{
        upgrade: fn transport, socket ->
          send(observer, :deadline_request_entered)
          transport.recv(socket, 0, 2_000)
        end
      })

    task =
      Task.async(fn ->
        Incus.raw_query(%{connection | timeout: 1_000}, context.binding, "GET", "/1.0", [])
      end)

    assert_receive :deadline_request_entered, 2_000
    assert {:error, %Error{kind: :deadline}} = Task.await(task, 2_000)

    assert [%{method: "GET"}] = HTTPFixture.requests(fixture)
  end

  test "both buffered mutation facades preserve uncertainty and issue one accepted POST",
       context do
    for facade <- [:raw, :http] do
      {fixture, connection} = backend(context, %{raw: ""})

      result =
        case facade do
          :raw ->
            Incus.raw_query(connection, context.binding, "POST", "/1.0/instances", body: %{})

          :http ->
            {:ok, http} =
              HTTP.client(%Incus{connection: connection, context: context.binding, server: nil})

            HTTP.request(http, "POST", "/1.0/instances", body: "{}")
        end

      assert {:error, %Error{kind: :uncertain}} = result
      assert [%{method: "POST", body: "{}"}] = HTTPFixture.requests(fixture)
    end
  end

  defp backend(context, response) do
    fixture =
      start_supervised!(
        {HTTPFixture,
         transport: :gen_tcp,
         path: Path.join(context.root, "#{System.unique_integer([:positive])}.sock"),
         handler: fn _ -> response end},
        id: make_ref()
      )

    {fixture, Connection.unix!(HTTPFixture.endpoint(fixture).socket, owner: :closed_fixture)}
  end
end
