defmodule Opsmaru.Incus.Gateway.Policy do
  @moduledoc """
  The single admission path shared by every gateway protocol adapter.

  `admit/2` runs, in order and before any backend connection:

    1. canonical route and path checks (`/`, `/1.0`, `/1.0/*`; no dot segments,
       NUL or backslash, raw or percent-encoded; an encoded `/` inside a
       segment stays, as image aliases need it);
    2. native selection parsing from the raw query, rejecting duplicate or
       malformed `project`, `target` and `all-projects` values;
    3. bounded admission;
    4. host readiness;
    5. host authorization.

  Each host callback runs in its own monitored process under the gateway's
  `callback_timeout` and is killed at the deadline, so a slow callback can never
  authorize later. Protocols not implemented by this gateway revision fail
  after authorization with an explicit `501`.
  """

  alias Opsmaru.Incus.Gateway
  alias Opsmaru.Incus.Gateway.{Admission, Failure, Request}

  defmodule Admitted do
    @moduledoc false
    defstruct [:slot, :admission, :grant, anonymous: false]
  end

  @implemented [:http]

  @doc """
  Build a request from adapter-supplied fields. Returns `{:ok, request}` or
  `{:error, failure}` without contacting the host or backend.
  """
  def request(fields) do
    path = Map.fetch!(fields, :path)
    query = Map.get(fields, :query, "")

    with :ok <- route(path),
         {:ok, selection} <- selection(query) do
      {:ok,
       %Request{
         protocol: Map.fetch!(fields, :protocol),
         method: Map.fetch!(fields, :method),
         path: path,
         query: query,
         project: selection.project,
         target: selection.target,
         all_projects: selection.all_projects,
         operation: operation(path),
         peer: Map.fetch!(fields, :peer),
         authorization: Map.get(fields, :authorization)
       }}
    end
  end

  @doc """
  Admit a request for `holder`. Returns `{:ok, %Admitted{}}` holding one
  admission slot, or `{:error, failure}` with no backend contact.
  """
  def admit(%Gateway{} = gateway, %Request{} = request, holder \\ self()) do
    case Admission.acquire(gateway.admission, holder) do
      {:ok, slot} ->
        case check_host(gateway, request) do
          {:ok, grant, anonymous} ->
            {:ok,
             %Admitted{slot: slot, admission: elem(slot, 0), grant: grant, anonymous: anonymous}}

          {:error, failure} ->
            Admission.release(slot)
            {:error, failure}
        end

      {:error, :capacity} ->
        {:error, Failure.new(503, "Gateway is at capacity", :not_sent)}

      {:error, :unavailable} ->
        {:error, Failure.new(503, "Gateway is not available", :not_sent)}
    end
  end

  @doc "Release an admitted exchange's slot."
  def release(%Admitted{slot: slot}), do: Admission.release(slot)

  defp check_host(gateway, request) do
    host = gateway.host
    config = gateway.host_config
    timeout = gateway.callback_timeout

    case callback(fn -> host.ready?(config) end, timeout) do
      {:ok, true} -> authorize(gateway, request)
      _ -> {:error, Failure.new(503, "Gateway host is not ready", :not_sent)}
    end
  end

  defp authorize(gateway, request) do
    result =
      callback(
        fn -> gateway.host.authorize(request, gateway.host_config) end,
        gateway.callback_timeout
      )

    case result do
      {:ok, {:ok, grant}} ->
        with :ok <- implemented(request),
             :ok <- recheck(gateway, request, grant) do
          {:ok, grant, false}
        end

      {:ok, {:error, :unauthenticated}} ->
        if anonymous_route?(request),
          do: {:ok, nil, true},
          else: {:error, Failure.new(403, "not authorized", :not_sent)}

      _ ->
        {:error, Failure.new(403, "not authorized", :not_sent)}
    end
  end

  defp anonymous_route?(%Request{protocol: :http, method: "GET", path: path}),
    do: path in ["/", "/1.0"]

  defp anonymous_route?(%Request{protocol: :http, method: "POST", path: "/1.0/certificates"}),
    do: true

  defp anonymous_route?(_), do: false

  @doc "Shared bounded expiry/revocation check; never obtains another grant."
  def recheck(gateway, request, grant) do
    timeout = min(gateway.callback_timeout, div(gateway.recheck_interval, 4))

    case callback(fn -> gateway.host.valid?(request, grant, gateway.host_config) end, timeout) do
      {:ok, true} -> :ok
      _ -> {:error, Failure.new(403, "Authorization expired or revoked", :not_sent)}
    end
  end

  defp implemented(%Request{protocol: protocol}) when protocol in @implemented, do: :ok

  defp implemented(_),
    do:
      {:error, Failure.new(501, "Protocol upgrade is not implemented by this gateway", :not_sent)}

  @doc false
  # Run one host callback in its own monitored process with a hard deadline.
  def callback(fun, timeout) do
    owner = self()
    deadline = System.monotonic_time(:millisecond) + timeout

    {pid, monitor} =
      spawn_monitor(fn ->
        worker = self()
        spawn(fn -> watch_callback(owner, worker, deadline) end)

        result =
          try do
            value = fun.()
            if System.monotonic_time(:millisecond) <= deadline, do: {:ok, value}, else: :failed
          rescue
            _ -> :failed
          catch
            _, _ -> :failed
          end

        exit({:shutdown, {:callback, result}})
      end)

    receive do
      {:DOWN, ^monitor, :process, ^pid, {:shutdown, {:callback, {:ok, value}}}} -> {:ok, value}
      {:DOWN, ^monitor, :process, ^pid, _} -> {:error, :failed}
    after
      timeout ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^monitor, :process, ^pid, _} -> :ok
        end

        {:error, :timeout}
    end
  end

  defp watch_callback(owner, worker, deadline) do
    owner_monitor = Process.monitor(owner)
    worker_monitor = Process.monitor(worker)

    receive do
      {:DOWN, ^owner_monitor, :process, ^owner, _} -> Process.exit(worker, :kill)
      {:DOWN, ^worker_monitor, :process, ^worker, _} -> :ok
    after
      max(0, deadline - System.monotonic_time(:millisecond)) -> Process.exit(worker, :kill)
    end
  end

  @doc false
  def route(path) when is_binary(path) and byte_size(path) <= 8_192 do
    cond do
      not canonical?(path) ->
        {:error, Failure.new(404, "not found", :not_sent)}

      unsafe?(path) ->
        {:error, Failure.new(400, "Invalid request path", :not_sent)}

      true ->
        :ok
    end
  end

  def route(_), do: {:error, Failure.new(414, "Request path is too long", :not_sent)}

  defp canonical?(path), do: path in ["/", "/1.0"] or String.starts_with?(path, "/1.0/")

  defp unsafe?(path) do
    String.contains?(path, [<<0>>, "\\"]) or
      Enum.any?(String.split(path, "/"), fn segment ->
        case decode(segment) do
          {:ok, decoded} -> decoded in [".", ".."] or String.contains?(decoded, [<<0>>, "\\"])
          :error -> true
        end
      end)
  end

  # Go rejects a `%` not followed by two hex digits; Elixir's decoders keep it.
  @bad_escape ~r/%(?![0-9A-Fa-f]{2})/

  defp decode(value) do
    if Regex.match?(@bad_escape, value), do: :error, else: {:ok, URI.decode(value)}
  end

  @selectors %{"project" => :project, "target" => :target, "all-projects" => :all_projects}

  @doc false
  # The backend reads selections with Go's url.ParseQuery and silently falls
  # back to the default project when the whole query fails to parse (for
  # example on a `;` separator or a bad escape). Reject every such query, and
  # duplicates, so the selection the host authorizes is the one the backend
  # uses.
  def selection(query) when is_binary(query) and byte_size(query) <= 65_536 do
    pairs =
      cond do
        query == "" -> []
        String.contains?(query, ";") -> [:invalid]
        true -> String.split(query, "&")
      end

    Enum.reduce_while(pairs, {:ok, %{}}, fn
      :invalid, _ ->
        {:halt, :invalid}

      pair, {:ok, found} ->
        {key, value} =
          case String.split(pair, "=", parts: 2) do
            [key, value] -> {key, value}
            [key] -> {key, ""}
          end

        with {:ok, key} <- decode_form(key),
             {:ok, value} <- decode_form(value) do
          select(found, Map.fetch(@selectors, key), value)
        else
          :error -> {:halt, :invalid}
        end
    end)
    |> case do
      {:ok, found} ->
        {:ok,
         %{
           project: blank(Map.get(found, :project)),
           target: blank(Map.get(found, :target)),
           all_projects: true?(Map.get(found, :all_projects))
         }}

      _ ->
        {:error, Failure.new(400, "Ambiguous or invalid project/target selection", :not_sent)}
    end
  end

  def selection(_), do: {:error, Failure.new(414, "Request query is too long", :not_sent)}

  defp select(found, :error, _value), do: {:cont, {:ok, found}}

  defp select(found, {:ok, name}, value) do
    if Map.has_key?(found, name),
      do: {:halt, :ambiguous},
      else: {:cont, {:ok, Map.put(found, name, value)}}
  end

  defp decode_form(value) do
    if Regex.match?(@bad_escape, value), do: :error, else: {:ok, URI.decode_www_form(value)}
  end

  defp blank(nil), do: nil
  defp blank(""), do: nil
  defp blank(value), do: value

  # The backend's util.IsTrue: anything else, including absence, is false.
  defp true?(nil), do: false
  defp true?(value), do: String.downcase(value) in ["true", "1", "yes", "on"]

  defp operation(path) do
    case String.split(path, "/") do
      ["", "1.0", "operations", id | _] when id != "" ->
        case decode(id) do
          {:ok, id} -> id
          :error -> nil
        end

      _ ->
        nil
    end
  end
end
