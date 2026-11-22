defmodule Opsmaru.Incus.Gateway.Identity do
  @moduledoc """
  Bounded public identity mediation. The host supplies explicitly verified
  backend metadata bound to the fixed connection. No discovery probe occurs.
  The origin and addresses must be HTTPS `host:port` authorities with no
  path or user information. With the default `identity_scope: :public` the
  host must be a public IP literal or a dotted DNS name; with `:local` it may
  also be a loopback or private-network IP literal (`127.0.0.0/8`, `::1`,
  `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `100.64.0.0/10`,
  `fc00::/7`), `localhost`, `*.localhost` or a single-label name. Unspecified,
  link-local, multicast and reserved IPs and IPv4-mapped IPv6 addresses are
  refused in both scopes, and the guest's own addresses are never served.
  The conservative extension allowlist covers the relayed HTTP features the
  gateway forwards unchanged (request fields, query parameters and routes)
  plus the WebSocket-gated and raw-upgrade features, and depends on the
  available optional protocol adapters. The host must approve only capabilities
  of protocols it actually mounts and of its verified backend. Migration
  extensions require WebSockets; clustering, token issuance, metrics trust and
  access reports remain excluded.
  """

  alias Opsmaru.Incus.Gateway.{Failure, Policy}

  # Plain HTTP relay: routes, request fields and query parameters the gateway
  # already forwards unchanged.
  # Discovery, trust and instances
  @relay_base ~w(certificate_update instances api_filtering instance_get_full
                 instance_create_start file_delete images_push_relay)
  # Projects
  @relay_projects ~w(projects project_usage projects_force_delete container_copy_project
                     instance_project_move storage_volume_project_move)
  # All-projects listings
  @relay_all_projects ~w(images_all_projects instance_all_projects network_acls_all_projects
                         network_zones_all_projects networks_all_projects
                         operations_get_query_all_projects profiles_all_projects
                         storage_buckets_all_projects storage_volumes_all_projects)
  # Storage
  @relay_storage ~w(storage storage_api_project storage_api_volume_rename
                    storage_api_volume_snapshots storage_volume_full storage_volume_state
                    storage_volumes_rebuild custom_volume_refresh
                    custom_volume_refresh_exclude_older_snapshots storage_buckets
                    storage_bucket_full storage_buckets_create_credentials instance_pool_move)
  # Networks
  @relay_networks ~w(network network_acl network_acl_log network_address_set network_allocations
                     network_dns network_dns_records network_forward network_integrations
                     network_leases network_load_balancer network_load_balancer_state
                     network_peer network_state instance_nic_network)
  # Instances/files/snapshots
  @relay_instances ~w(container_full container_edit_metadata container_exec_user_group_cwd
                      container_exec_recording dependent directory_manipulation file_append
                      file_symlinks instance_bulk_state_change instance_move_config
                      instance_snapshot_disk_only_restore instances_rebuild instances_debug_repair
                      snapshot_expiry snapshot_expiry_creation)
  # Copy options
  @relay_copy ~w(container_incremental_copy container_only_migration instance_allow_inconsistent_copy)
  # Images
  @relay_images ~w(image_compression_algorithm image_copy_profile image_create_aliases image_force_refresh)
  # Server information
  @relay_server_info ~w(resources resources_v2 warnings metadata_configuration)
  # Backups/ISO
  @relay_backups ~w(container_backup container_backup_override_pool backup_override_config
                    backup_override_name custom_volume_backup storage_bucket_backup direct_backup
                    custom_volume_iso)

  @extensions @relay_base ++
                @relay_projects ++
                @relay_all_projects ++
                @relay_storage ++
                @relay_networks ++
                @relay_instances ++
                @relay_copy ++
                @relay_images ++
                @relay_server_info ++
                @relay_backups

  # WebSocket-gated: the console stream and instance/volume migration use the
  # operation WebSocket. The pinned client checks console_force only on a
  # console request, and the snapshot entries only while migrating.
  @websocket_extensions ~w(console container_push container_push_target
                           storage_api_local_volume_handling storage_api_remote_volume_handling
                           console_force storage_api_remote_volume_snapshot_copy
                           container_snapshot_stateful_migration)

  @raw_extensions ~w(instance_nbd custom_volume_sftp storage_volume_nbd)

  def load(gateway, request) do
    result =
      Policy.callback(
        fn ->
          with {:ok, identity} <- gateway.host.identity(request, gateway.host_config),
               true <- valid?(identity, gateway) do
            {:ok,
             Map.update!(
               identity,
               :api_extensions,
               &Enum.filter(&1, fn x -> x in supported_extensions() end)
             )}
          end
        end,
        gateway.callback_timeout
      )

    case result do
      {:ok, {:ok, identity}} -> {:ok, identity}
      _ -> {:error, Failure.new(503, "Gateway identity is unavailable", :not_sent)}
    end
  end

  @doc false
  def supported_extensions do
    websocket =
      if Code.ensure_loaded?(Opsmaru.Incus.Gateway.WebSocket), do: @websocket_extensions, else: []

    raw =
      if Code.ensure_loaded?(Opsmaru.Incus.Gateway.CowboyHandler), do: @raw_extensions, else: []

    @extensions ++ websocket ++ raw
  end

  defp valid?(
         %{
           origin: origin,
           addresses: addresses,
           certificate: certificate,
           connection: connection,
           api_extensions: extensions
         } = identity,
         gateway
       ) do
    scope = gateway.identity_scope

    :erlang.external_size(Map.delete(identity, :connection)) <= gateway.max_identity_bytes and
      connection == gateway.connection and origin?(origin, scope) and is_list(addresses) and
      Enum.all?(addresses, &address?(&1, scope)) and is_binary(certificate) and
      certificate?(certificate) and is_list(extensions) and Enum.all?(extensions, &is_binary/1)
  end

  defp valid?(_, _), do: false

  defp origin?(origin, scope) when is_binary(origin) do
    uri = URI.parse(origin)

    uri.scheme == "https" and host?(uri.host, scope) and uri.userinfo == nil and
      uri.path in [nil, ""] and uri.query == nil and uri.fragment == nil and port?(uri.port)
  end

  defp origin?(_, _scope), do: false

  defp address?(address, scope) when is_binary(address), do: origin?("https://" <> address, scope)
  defp address?(_, _scope), do: false
  defp port?(port), do: is_integer(port) and port in 1..65_535

  # No DNS lookups. Hosts remain responsible for DNS; literal link-local,
  # unspecified, multicast and reserved addresses and socket names are always
  # refused, and loopback and private-network ones unless the host declared a
  # local gateway.
  defp host?(host, scope) when is_binary(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, ip} -> public_ip?(ip) or (scope == :local and local_ip?(ip))
      _ -> public_dns?(host) or (scope == :local and local_dns?(host))
    end
  end

  defp host?(_, _scope), do: false

  defp local_ip?({127, _, _, _}), do: true
  defp local_ip?({10, _, _, _}), do: true
  defp local_ip?({172, b, _, _}), do: b in 16..31
  defp local_ip?({192, 168, _, _}), do: true
  defp local_ip?({100, b, _, _}), do: b in 64..127
  defp local_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp local_ip?({a, _, _, _, _, _, _, _}), do: a in 0xFC00..0xFDFF
  defp local_ip?(_), do: false

  defp local_dns?(host) do
    host = String.downcase(host)

    host == "localhost" or
      (String.ends_with?(host, ".localhost") and public_dns_syntax?(host)) or
      Regex.match?(~r/\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\z/, host)
  end

  defp public_dns_syntax?(host), do: Regex.match?(~r/\A[a-zA-Z0-9.-]+\z/, host)

  defp public_dns?(host) do
    host != "localhost" and String.contains?(host, ".") and
      Regex.match?(~r/\A[a-zA-Z0-9.-]+\z/, host) and not String.ends_with?(host, ".localhost")
  end

  defp public_ip?({a, b, _, _}) do
    a not in [0, 10, 127] and not (a == 172 and b in 16..31) and
      not (a == 192 and b == 168) and not (a == 169 and b == 254) and
      not (a == 100 and b in 64..127) and a < 224
  end

  defp public_ip?({0, 0, 0, 0, 0, 0, 0, value}) when value in [0, 1], do: false
  defp public_ip?({0, 0, 0, 0, 0, 0xFFFF, _, _}), do: false

  defp public_ip?({a, _, _, _, _, _, _, _}),
    do: a not in 0xFC00..0xFDFF and a not in 0xFE80..0xFEBF and a < 0xFF00

  defp certificate?(pem) do
    case :public_key.pem_decode(pem) do
      [{:Certificate, der, :not_encrypted}] ->
        :public_key.pkix_decode_cert(der, :otp)
        true

      _ ->
        false
    end
  end

  def discovery("/", _identity), do: envelope(["/1.0"])

  def discovery("/1.0", identity) do
    envelope(%{
      "api_version" => "1.0",
      "api_status" => "stable",
      "auth" => "untrusted",
      "public" => false,
      "auth_methods" => ["tls"],
      "api_extensions" => identity.api_extensions
    })
  end

  def envelope(metadata),
    do: %{"type" => "sync", "status" => "Success", "status_code" => 200, "metadata" => metadata}

  def rewrite(body, identity, limit) do
    with {:ok, %{"metadata" => %{"environment" => environment} = metadata} = envelope} <-
           Jason.decode(body),
         true <- is_map(environment),
         extensions when is_list(extensions) <- Map.get(metadata, "api_extensions", []) do
      environment =
        environment
        |> Map.put("addresses", identity.addresses)
        |> Map.put("certificate", identity.certificate)

      extensions = Enum.filter(extensions, &(&1 in identity.api_extensions))

      body =
        envelope
        |> Map.put(
          "metadata",
          metadata |> Map.put("environment", environment) |> Map.put("api_extensions", extensions)
        )
        |> Jason.encode!()

      if byte_size(body) <= limit, do: {:ok, body}, else: :error
    else
      _ -> :error
    end
  end
end
