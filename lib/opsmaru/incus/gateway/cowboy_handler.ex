if Code.ensure_loaded?(:cowboy_req) do
  defmodule Opsmaru.Incus.Gateway.CowboyHandler do
    @moduledoc """
    Same-listener Cowboy dispatch for native SFTP/NBD upgrades.

    Mount as the catch-all Cowboy handler with `%{gateway: gateway_or_mfa,
    fallback: {handler, handler_opts}}`. Ordinary HTTP and WebSocket requests
    go to the host's fallback (normally `Plug.Cowboy.Handler`). This module
    opens no listener. Only HTTP/1.1 GET instance and storage-volume SFTP/NBD
    routes can switch; all raw attempts use the shared host policy first.
    """
    @behaviour :cowboy_handler
    alias Opsmaru.Incus.Gateway
    alias Opsmaru.Incus.Gateway.{Exchange, Failure, Headers, Policy, RawRelay, RawTunnel}

    @impl true
    def init(req, opts) do
      if raw?(req), do: raw(req, opts), else: fallback(req, opts)
    end

    defp raw?(req) do
      value = :cowboy_req.header("upgrade", req, "") |> String.downcase()
      native?(req.path) and value != "" and value != "websocket"
    end

    defp native?(path), do: path in ["/", "/1.0"] or String.starts_with?(path, "/1.0/")

    defp fallback(req, %{fallback: {handler, opts}}) do
      case handler.init(req, opts) do
        {:ok, req, state} ->
          {:ok, req, {:fallback, handler, state}}

        {protocol, req, state} ->
          {__MODULE__, req, {protocol, handler, state}}

        {protocol, req, state, upgrade_opts} ->
          {__MODULE__, req, {protocol, handler, state}, upgrade_opts}
      end
    end

    defp fallback(req, opts) do
      exchange = start(req, nil, if(websocket?(req), do: :websocket, else: :http))

      reject(
        req,
        opts,
        Failure.new(404, "Not found", :not_sent, reason: :not_configured),
        exchange
      )
    end

    defp websocket?(req),
      do: String.downcase(:cowboy_req.header("upgrade", req, "")) == "websocket"

    @doc false
    def upgrade(req, env, __MODULE__, {protocol, handler, state}),
      do: protocol.upgrade(req, env, handler, state)

    @doc false
    def upgrade(req, env, __MODULE__, {protocol, handler, state}, opts),
      do: protocol.upgrade(req, env, handler, state, opts)

    @doc false
    @impl true
    def terminate(reason, req, {:fallback, handler, state}) do
      if function_exported?(handler, :terminate, 3),
        do: handler.terminate(reason, req, state),
        else: :ok
    end

    def terminate(_, _, _), do: :ok

    defp raw(req, opts) do
      resolved = resolve(Map.get(opts, :gateway))
      exchange = start(req, host(resolved), :raw)

      try do
        relay(req, opts, resolved, exchange)
      catch
        kind, reason ->
          Exchange.interrupt(exchange, :killed)
          Exchange.finish(exchange, :ended)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end
    end

    defp relay(req, opts, resolved, exchange) do
      with {:ok, gateway} <- resolved,
           _ <- Exchange.path(exchange, req.path),
           {:ok, request} <- Policy.request(fields(req)),
           _ <- Exchange.request(exchange, request),
           {:ok, relay, response} <-
             RawRelay.start(gateway, request, req.pid, fn -> validate(req, gateway) end, exchange) do
        case response do
          {:upgrade, headers} ->
            case RawRelay.handoff(relay) do
              :ok ->
                # The actor owns the exchange from here and reports its end.
                Exchange.status(exchange, 101)
                Exchange.transfer(exchange, relay)
                :cowboy_req.cast({:switch_protocol, header_map(headers), RawTunnel, relay}, req)
                {:ok, req, opts}

              {:error, failure} ->
                reject(req, opts, failure, exchange)
            end

          {:response, status, headers, body} ->
            Exchange.status(exchange, status)
            Exchange.response_bytes(exchange, byte_size(body))
            req = :cowboy_req.reply(status, header_map(headers), body, req)
            Exchange.finish(exchange, :ended)
            {:ok, req, opts}
        end
      else
        {:error, %Failure{} = failure} -> reject(req, opts, failure, exchange)
      end
    end

    defp start(req, host, protocol) do
      {address, port} = :cowboy_req.peer(req)

      Exchange.start(%{
        host: host,
        protocol: protocol,
        method: req.method,
        peer: %{address: address, port: port, certificate: certificate(req)}
      })
    end

    defp host({:ok, %Gateway{host: host}}), do: host
    defp host(_), do: nil

    defp resolve(%Gateway{} = gateway), do: {:ok, gateway}

    defp resolve({module, function, args}) do
      case apply(module, function, args) do
        %Gateway{} = gateway ->
          {:ok, gateway}

        _ ->
          {:error,
           Failure.new(503, "Gateway is not configured", :not_sent, reason: :not_configured)}
      end
    rescue
      _ ->
        {:error,
         Failure.new(503, "Gateway is not configured", :not_sent, reason: :not_configured)}
    catch
      _, _ ->
        {:error,
         Failure.new(503, "Gateway is not configured", :not_sent, reason: :not_configured)}
    end

    defp resolve(_),
      do:
        {:error,
         Failure.new(503, "Gateway is not configured", :not_sent, reason: :not_configured)}

    defp fields(req) do
      headers = :cowboy_req.headers(req)
      {address, port} = :cowboy_req.peer(req)

      %{
        protocol: :raw,
        method: req.method,
        path: req.path,
        query: req.qs,
        peer: %{address: address, port: port, certificate: certificate(req)},
        authorization: Map.get(headers, "authorization")
      }
    end

    defp validate(req, gateway) do
      headers = Map.to_list(:cowboy_req.headers(req))
      protocol = :cowboy_req.header("upgrade", req, "") |> String.downcase()
      connection = :cowboy_req.header("connection", req, "") |> tokens()

      with true <- req.version == :"HTTP/1.1" and req.method == "GET",
           true <-
             protocol in ["sftp", "nbd"] and "upgrade" in connection and valid_tokens?(connection),
           true <- route?(req.path, protocol) and not :cowboy_req.has_body(req),
           {:ok, headers, :none} <- Headers.request(headers, gateway.max_header_bytes, 0) do
        {:ok, protocol, headers}
      else
        {:error, %Failure{} = failure} ->
          {:error, failure}

        _ ->
          {:error,
           Failure.new(400, "Invalid native raw upgrade", :not_sent, reason: :invalid_request)}
      end
    end

    defp route?(path, protocol) do
      case String.split(path, "/") do
        ["", "1.0", "instances", name, ^protocol] ->
          name != ""

        ["", "1.0", "storage-pools", pool, "volumes", type, name, ^protocol] ->
          pool != "" and type != "" and name != ""

        _ ->
          false
      end
    end

    defp certificate(req) do
      case :cowboy_req.cert(req) do
        :undefined -> nil
        cert -> cert
      end
    end

    defp valid_tokens?(tokens) do
      Enum.all?(tokens, &Regex.match?(~r/\A[!#$%&'*+\-.^_`|~0-9a-z]+\z/, &1))
    end

    defp tokens(value),
      do: value |> String.downcase() |> String.split(",") |> Enum.map(&String.trim/1)

    defp header_map(headers) do
      Enum.reduce(headers, %{}, fn
        {"set-cookie", value}, acc -> Map.update(acc, "set-cookie", [value], &(&1 ++ [value]))
        {name, value}, acc -> Map.update(acc, name, value, &[&1, ", ", value])
      end)
    end

    defp reject(req, opts, failure, exchange) do
      {_, _, body} = Failure.encode(failure)
      headers = %{"content-type" => "application/json", "cache-control" => "no-store"}
      req = :cowboy_req.reply(failure.status, headers, body, req)
      Exchange.status(exchange, failure.status)
      Exchange.response_bytes(exchange, byte_size(body))
      Exchange.finish(exchange, failure)
      {:ok, req, opts}
    end
  end
end
