defmodule Opsmaru.Incus.Streams do
  @moduledoc """
  Native Incus binary stream helpers for the official v7.0.1 typed methods:

  - `metrics/2` (GetMetrics)
  - `network_acl_log/3` (GetNetworkACLLogfile)
  - `instance_logfile/4` (GetInstanceLogfile)
  - `instance_console_log/3` (GetInstanceConsoleLog)
  - `instance_template_file/4` (GetInstanceTemplateFile)
  - `create_instance_template_file/4` (CreateInstanceTemplateFile)
  - `instance_debug_memory/4` (GetInstanceDebugMemory)

  Every download delivers bounded binary chunks to an explicitly acknowledged
  `sink/1` that returns `:ok`; the template-file upload reads a host
  enumerable of bounded binary chunks. Bodies are never JSON/base64 encoded,
  written to host filesystem paths, buffered by this module or replayed.
  Native project/target selection and required extensions are preserved; a
  missing extension fails before any backend contact. All failures use the
  shared `Opsmaru.Incus.Error` contract: explicit native error envelopes keep
  kind `:native` (including rejected POSTs), while ambiguous transport,
  deadline or disconnect failures of a POST are reported `:uncertain`
  (possibly accepted). No failure is retried. This is a bounded slice, not a
  complete-port claim.
  """
  alias Opsmaru.Incus
  alias Opsmaru.Incus.{Error, Transfer}

  @doc """
  GetMetrics: `GET /1.0/metrics` with the `metrics` extension, streaming the
  text/OpenMetrics body to `sink/1` under the shared transfer deadline and
  byte bounds. Returns `{:ok, %Opsmaru.Incus.Transfer{}}` or `{:error,
  %Error{}}`.
  """
  def metrics(client, sink) when is_function(sink, 1) do
    with :ok <- Incus.require_extension(client, "metrics") do
      Transfer.download(client, "/1.0/metrics", sink)
    end
  end

  @doc "GetNetworkACLLogfile: stream `GET /1.0/network-acls/{name}/log` to `sink/1`."
  def network_acl_log(client, name, sink) when is_function(sink, 1) do
    with :ok <- Incus.require_extension(client, "network_acl_log"),
         :ok <- segment(name) do
      Transfer.download(client, "/1.0/network-acls/" <> escape(name) <> "/log", sink)
    end
  end

  @doc """
  GetInstanceLogfile: stream `GET /1.0/instances/{name}/logs/{filename}` to
  `sink/1`. The native method checks no API extension.
  """
  def instance_logfile(client, name, filename, sink) when is_function(sink, 1) do
    with :ok <- segment(name), :ok <- segment(filename) do
      Transfer.download(
        client,
        "/1.0/instances/" <> escape(name) <> "/logs/" <> escape(filename),
        sink
      )
    end
  end

  @doc """
  GetInstanceConsoleLog: stream `GET /1.0/instances/{name}/console` to
  `sink/1` after checking the native `console` extension.
  """
  def instance_console_log(client, name, sink) when is_function(sink, 1) do
    with :ok <- Incus.require_extension(client, "console"),
         :ok <- segment(name) do
      Transfer.download(client, "/1.0/instances/" <> escape(name) <> "/console", sink)
    end
  end

  @doc """
  GetInstanceTemplateFile: stream
  `GET /1.0/instances/{name}/metadata/templates?path={template}` to `sink/1`
  after checking the native `container_edit_metadata` extension. The template
  is form-encoded exactly like the official client's `url.QueryEscape`.
  """
  def instance_template_file(client, name, template, sink)
      when is_function(sink, 1) do
    with :ok <- Incus.require_extension(client, "container_edit_metadata"),
         :ok <- segment(name),
         :ok <- form_value(template) do
      Transfer.download(
        client,
        "/1.0/instances/" <> escape(name) <> "/metadata/templates?path=" <> form(template),
        sink
      )
    end
  end

  @doc """
  CreateInstanceTemplateFile: `POST` the host enumerable `source` of bounded
  binary chunks to
  `/1.0/instances/{name}/metadata/templates?path={template}` with native
  `Content-Type: application/octet-stream` after checking the
  `container_edit_metadata` extension. Returns the native sync envelope on
  success; a failure may be `:uncertain` (possibly accepted) and is never
  retried.
  """
  def create_instance_template_file(client, name, template, source) do
    with :ok <- Incus.require_extension(client, "container_edit_metadata"),
         :ok <- segment(name),
         :ok <- form_value(template) do
      Transfer.upload(
        client,
        "/1.0/instances/" <> escape(name) <> "/metadata/templates?path=" <> form(template),
        source,
        [{"content-type", "application/octet-stream"}]
      )
    end
  end

  @doc """
  GetInstanceDebugMemory: stream
  `GET /1.0/instances/{name}/debug/memory?format={format}&instance-type=virtual-machine`
  to `sink/1`. The `instance-type=virtual-machine` query value is part of the
  official client's native request. The native method checks no API
  extension.
  """
  def instance_debug_memory(client, name, format, sink) when is_function(sink, 1) do
    with :ok <- segment(name), :ok <- form_value(format) do
      query = URI.encode_query([{"format", format}, {"instance-type", "virtual-machine"}])

      Transfer.download(
        client,
        "/1.0/instances/" <> escape(name) <> "/debug/memory?" <> query,
        sink
      )
    end
  end

  # url.PathEscape: unreserved characters (including '~') pass through.
  defp escape(value), do: URI.encode(value, &URI.char_unreserved?/1)

  # Elixir's form encoding matches Go's url.QueryEscape (space -> "+").
  defp form(value), do: URI.encode_query([{"path", value}]) |> String.replace_prefix("path=", "")

  defp segment(value),
    do:
      if(is_binary(value) and byte_size(value) in 1..1024,
        do: :ok,
        else: {:error, %Error{kind: :invalid_arguments}}
      )

  defp form_value(value),
    do:
      if(
        is_binary(value) and
          byte_size(value) <= 1024 and
          not String.contains?(value, ["\r", "\n", <<0>>]),
        do: :ok,
        else: {:error, %Error{kind: :invalid_arguments}}
      )
end
