if Code.ensure_loaded?(Plug.Conn) and Code.ensure_loaded?(:cowboy_websocket) do
  defmodule Opsmaru.Incus.Gateway.WebSocket do
    @moduledoc """
    Native WebSocket adapter for a host-owned Plug.Cowboy listener.

    Data and native JSON control messages are relayed unchanged. RFC 6455
    ping/pong negotiation is local to each independently negotiated connection;
    backend close codes/reasons are preserved. No Phoenix framing is added.
    """
    alias Opsmaru.Incus.Gateway.{Failure, Headers, HTTPRelay, WebSocketRelay}

    def upgrade(conn, gateway, request, admitted) do
      with {:ok, owner} <- frontend(conn),
           :ok <- handshake(conn, request),
           {:ok, headers, :none} <-
             Headers.request(conn.req_headers, gateway.max_header_bytes, 0),
           {:ok, relay, response_headers} <-
             WebSocketRelay.open(gateway, request, admitted, owner, strip_negotiation(headers)) do
        conn = %{conn | resp_headers: response_headers ++ conn.resp_headers}

        try do
          :ok = WebSocketRelay.commit(relay)

          Plug.Conn.upgrade_adapter(
            conn,
            :websocket,
            {__MODULE__, %{relay: relay},
             %{
               compress: false,
               active_n: 1,
               idle_timeout: gateway.idle_timeout,
               max_frame_size:
                 min(gateway.max_request_bytes, gateway.connection.max_response_bytes),
               validate_utf8: true
             }}
          )
        rescue
          _ ->
            WebSocketRelay.close(relay)
            HTTPRelay.fail(conn, Failure.new(501, "WebSocket adapter is unavailable", :sent))
        end
      else
        {:http, status, headers, body} ->
          conn = %{conn | resp_headers: headers ++ conn.resp_headers}

          Plug.Conn.send_resp(conn, status, body)

        {:error, %Failure{} = failure} ->
          HTTPRelay.fail(conn, failure)

        _ ->
          HTTPRelay.fail(conn, Failure.new(400, "Invalid WebSocket upgrade", :not_sent))
      end
    end

    defp frontend(%Plug.Conn{adapter: {Plug.Cowboy.Conn, %{pid: pid, version: :"HTTP/1.1"}}}),
      do: {:ok, pid}

    defp frontend(_),
      do: {:error, Failure.new(501, "WebSockets require a native HTTP/1.1 adapter", :not_sent)}

    defp handshake(conn, %{method: "GET", path: path}) do
      key = Plug.Conn.get_req_header(conn, "sec-websocket-key")

      valid_key =
        case key do
          [value] -> match?({:ok, <<_::128>>}, Base.decode64(value))
          _ -> false
        end

      connection =
        for value <- Plug.Conn.get_req_header(conn, "connection"),
            token <- String.split(value, ","),
            do: token |> String.trim() |> String.downcase()

      if native_route?(path) and valid_key and "upgrade" in connection and
           Plug.Conn.get_req_header(conn, "sec-websocket-version") == ["13"] and
           Plug.Conn.get_req_header(conn, "sec-websocket-protocol") == [] and
           Plug.Conn.get_req_header(conn, "transfer-encoding") == [] and
           not :cowboy_req.has_body(elem(conn.adapter, 1)),
         do: :ok,
         else: {:error, Failure.new(400, "Invalid WebSocket upgrade", :not_sent)}
    end

    defp handshake(_, _), do: {:error, Failure.new(400, "Invalid WebSocket upgrade", :not_sent)}

    defp native_route?("/1.0/events"), do: true
    defp native_route?(path), do: Regex.match?(~r{\A/1\.0/operations/[^/]+/websocket\z}, path)

    defp strip_negotiation(headers),
      do: Enum.reject(headers, fn {name, _} -> String.starts_with?(name, "sec-websocket-") end)

    def websocket_init(state) do
      case WebSocketRelay.attach(state.relay) do
        :ok -> {[], Map.merge(state, %{monitor: Process.monitor(state.relay), input_paused: nil})}
        _ -> {[{:close, 1011, "Gateway channel ended"}], state}
      end
    end

    def websocket_handle({kind, payload}, state) when kind in [:text, :binary] do
      case WebSocketRelay.send_frame(state.relay, {kind, payload}) do
        :ok -> {[], state}
        {:pause, ref} -> {[{:active, false}], %{state | input_paused: ref}}
        _ -> {[{:close, 1011, "Gateway channel ended"}], state}
      end
    end

    # Cowboy answers ping automatically. These are hop-local RFC controls,
    # distinct from native Incus JSON resize/signal/exit control messages.
    def websocket_handle(_, state), do: {[], state}

    def websocket_info({:gateway_ws_frames, relay, frames}, %{relay: relay} = state) do
      send(self(), {:gateway_ws_ack, relay})
      {frames, state}
    end

    def websocket_info({:gateway_ws_ack, relay}, %{relay: relay} = state) do
      WebSocketRelay.ack(relay)
      {[], state}
    end

    def websocket_info(
          {:gateway_ws_resume, relay, ref},
          %{relay: relay, input_paused: ref} = state
        ),
        do: {[{:active, true}], %{state | input_paused: nil}}

    def websocket_info({:gateway_ws_close, relay, code, reason}, %{relay: relay} = state),
      do: {[{:close, code, reason}], state}

    def websocket_info({:DOWN, ref, :process, relay, _}, %{relay: relay, monitor: ref} = state),
      do: {[{:close, 1011, "Gateway channel ended"}], state}

    def websocket_info(_, state), do: {[], state}

    def terminate({:remote, code, reason}, _, state),
      do: WebSocketRelay.close(state.relay, {:close, code, reason})

    def terminate(_, _, state), do: WebSocketRelay.close(state.relay)
  end
end
