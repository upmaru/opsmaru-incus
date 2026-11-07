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
    alias Opsmaru.Incus.Gateway.{Failure, Headers, Policy, RawRelay, RawTunnel}

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

    defp fallback(req, opts), do: reject(req, opts, Failure.new(404, "Not found", :not_sent))

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
      with {:ok, gateway} <- resolve(Map.get(opts, :gateway)),
           {:ok, request} <- Policy.request(fields(req)),
           {:ok, relay, response} <-
             RawRelay.start(gateway, request, req.pid, fn -> validate(req, gateway) end) do
        case response do
          {:upgrade, headers} ->
            case RawRelay.handoff(relay) do
              :ok ->
                :cowboy_req.cast({:switch_protocol, header_map(headers), RawTunnel, relay}, req)
                {:ok, req, opts}

              {:error, failure} ->
                reject(req, opts, failure)
            end

          {:response, status, headers, body} ->
            {:ok, :cowboy_req.reply(status, header_map(headers), body, req), opts}
        end
      else
        {:error, %Failure{} = failure} -> reject(req, opts, failure)
      end
    end

    defp resolve(%Gateway{} = gateway), do: {:ok, gateway}

    defp resolve({module, function, args}) do
      case apply(module, function, args) do
        %Gateway{} = gateway -> {:ok, gateway}
        _ -> {:error, Failure.new(503, "Gateway is not configured", :not_sent)}
      end
    rescue
      _ -> {:error, Failure.new(503, "Gateway is not configured", :not_sent)}
    catch
      _, _ -> {:error, Failure.new(503, "Gateway is not configured", :not_sent)}
    end

    defp resolve(_), do: {:error, Failure.new(503, "Gateway is not configured", :not_sent)}

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
        {:error, %Failure{} = failure} -> {:error, failure}
        _ -> {:error, Failure.new(400, "Invalid native raw upgrade", :not_sent)}
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

    defp reject(req, opts, failure) do
      {_, _, body} = Failure.encode(failure)
      headers = %{"content-type" => "application/json", "cache-control" => "no-store"}
      {:ok, :cowboy_req.reply(failure.status, headers, body, req), opts}
    end
  end
end
