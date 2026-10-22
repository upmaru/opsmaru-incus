defmodule Opsmaru.Incus.EndpointEvidenceTest do
  use ExUnit.Case, async: false
  alias Opsmaru.TestSupport.{EndpointEvidence, EndpointInventory}
  @manifest Jason.decode!(File.read!("priv/incus/endpoint-evidence.json"))

  setup_all do
    reference_dir = Path.expand("reference", __DIR__)
    env = [{"GOTOOLCHAIN", "local"}]

    {out, 0} =
      System.cmd(
        "mise",
        ["exec", "--", "go", "mod", "download", "-json", "github.com/lxc/incus/v7"],
        cd: reference_dir,
        env: env
      )

    module = Jason.decode!(out)
    assert module["Version"] == "v7.0.1"
    driver = Path.expand("../.integration/endpoint-evidence-driver", __DIR__)

    {out, status} =
      System.cmd("mise", ["exec", "--", "go", "build", "-o", driver, "./endpoints"],
        cd: reference_dir,
        env: env,
        stderr_to_stdout: true
      )

    assert status == 0, out
    {out, 0} = System.cmd(driver, [module["Dir"]])
    %{native: Jason.decode!(out)}
  end

  test "full inventory classifies every REST view and reconciles server registrations", %{
    native: native
  } do
    audit = Jason.decode!(File.read!("priv/incus/endpoint-inventory.json"))
    assert :ok = EndpointInventory.validate!(audit, native)

    [first | rest] = audit["entries"]
    [view | other_views] = first["documented_views"]
    views = [%{view | "selectors" => %{"recursion" => "99"}} | other_views]
    wrong_parameters = [%{view | "query_parameters" => ["absent"]} | other_views]
    # The first row is complete, so the invented completion targets a partial row.
    partial = Enum.find(audit["entries"], &(not &1["behavior_complete"]))

    invented =
      Enum.map(
        audit["entries"],
        &if(&1 == partial, do: %{&1 | "behavior_complete" => true}, else: &1)
      )

    for changed <- [
          %{audit | "entries" => rest},
          %{audit | "entries" => [%{first | "documented_views" => wrong_parameters} | rest]},
          %{audit | "entries" => [%{first | "documented_views" => views} | rest]},
          put_in(audit, ["helpers", "connect", "client"], ["Opsmaru.Incus", "absent", 2]),
          put_in(audit, ["baseline_evidence"], ["test/resource_slice_test.exs", "absent anchor"]),
          %{audit | "entries" => [first, first | rest]},
          put_in(audit, ["entries"], [Map.put(first, "methods", ["AbsentMethod"]) | rest]),
          put_in(audit, ["entries"], [Map.put(first, "backlog", "absent") | rest]),
          %{audit | "entries" => invented},
          put_in(audit, ["entries"], [Map.put(first, "documented_views", []) | rest]),
          %{audit | "server_sources" => %{}},
          %{audit | "supplemental_server_entries" => []},
          %{audit | "behavior_complete" => true},
          %{audit | "stream_contracts" => []}
        ] do
      assert_raise ExUnit.AssertionError, fn ->
        EndpointInventory.validate!(changed, native)
      end
    end
  end

  test "query parameters cannot borrow support from another recursion view", %{native: native} do
    audit = Jason.decode!(File.read!("priv/incus/endpoint-inventory.json"))

    gaps =
      for row <- audit["entries"],
          not String.starts_with?(row["pair"], "HEAD "),
          view <- row["documented_views"],
          {query, "unmapped_selector"} <- view["query_classification"],
          do: {row["pair"], query}

    assert gaps |> Enum.uniq() |> length() == 28
    assert length(gaps) == 38
    row = Enum.find(audit["entries"], &(&1["pair"] == "GET /1.0/instances"))
    names = Enum.find(row["documented_views"], &(&1["operation"] == "GET /1.0/instances"))
    assert names["methods"] == ["GetInstanceNames"]
    assert names["query_classification"]["filter"] == "unmapped_selector"
    assert names["query_classification"]["all-projects"] == "unmapped_selector"

    full = Enum.find(row["documented_views"], &String.ends_with?(&1["operation"], "?recursion=1"))
    assert full["query_classification"]["filter"] == "catalogue_contract"
    assert full["query_classification"]["all-projects"] == "catalogue_contract"

    views =
      Enum.map(row["documented_views"], fn view ->
        if view == names,
          do: put_in(view, ["query_classification", "filter"], "catalogue_contract"),
          else: view
      end)

    entries =
      Enum.map(
        audit["entries"],
        &if(&1 == row, do: %{row | "documented_views" => views}, else: &1)
      )

    assert_raise ExUnit.AssertionError, ~r/stale parameter classification/, fn ->
      EndpointInventory.validate!(%{audit | "entries" => entries}, native)
    end
  end

  test "full inventory fixture claims must match the selected evidence scope", %{native: native} do
    audit = Jason.decode!(File.read!("priv/incus/endpoint-inventory.json"))
    verified = Enum.find(audit["entries"], &(&1["pair"] == "GET /1.0/projects"))
    unrelated = Enum.find(audit["entries"], &(&1["pair"] == "GET /1.0/certificates"))

    for {row, replacement} <- [
          {verified, Map.delete(verified, "verified_scope")},
          {verified, Map.put(verified, "verified_scope", "invented_scope")},
          {unrelated, Map.put(unrelated, "verified_scope", "initial_inspection_v1")}
        ] do
      entries = Enum.map(audit["entries"], &if(&1 == row, do: replacement, else: &1))

      assert_raise ExUnit.AssertionError, ~r/fixture scope/, fn ->
        EndpointInventory.validate!(%{audit | "entries" => entries}, native)
      end
    end
  end

  test "135 selected pairs have pinned REST provenance and specific existing evidence", %{
    native: native
  } do
    assert :ok = EndpointEvidence.validate!(@manifest, native)

    assert Enum.sort(Enum.flat_map(@manifest["entries"], &List.wrap(&1["method"]))) ==
             Enum.sort(
               ~w(GetInstances CreateInstance GetInstance UpdateInstance PatchInstance DeleteInstance
               GetInstanceState UpdateInstanceState GetInstanceSnapshots CreateInstanceSnapshot
               GetInstanceSnapshot DeleteInstanceSnapshot GetImages GetImage DeleteImage
               GetOperations GetOperation DeleteOperation GetOperationWait ExecInstance
               GetProjects GetProject GetProfiles GetProfile GetNetworks GetNetwork
               GetStoragePools GetStoragePool GetStoragePoolVolumes GetStoragePoolVolume
               PatchProject PatchProfile PatchImage PatchInstanceSnapshot
               GetNetworkACLNames GetNetworkACL GetNetworkAddressSetNames GetNetworkAddressSet GetNetworkAllocations GetNetworkIntegrationNames GetNetworkIntegration GetNetworkZoneNames GetNetworkZone GetNetworkZoneRecords GetNetworkZoneRecord GetNetworkForwards GetNetworkForward GetNetworkLeases GetNetworkLoadBalancerAddresses GetNetworkLoadBalancer GetNetworkLoadBalancerState GetNetworkPeers GetNetworkPeer GetNetworkState
               DeleteNetworkACL DeleteNetworkAddressSet DeleteNetworkIntegration DeleteNetworkZone DeleteNetworkZoneRecord DeleteNetwork DeleteNetworkForward DeleteNetworkLoadBalancer DeleteNetworkPeer CreateNetworkACL RenameNetworkACL CreateNetworkAddressSet RenameNetworkAddressSet CreateNetworkIntegration RenameNetworkIntegration CreateNetworkZone CreateNetworkZoneRecord CreateNetwork RenameNetwork CreateNetworkForward CreateNetworkLoadBalancer CreateNetworkPeer UpdateNetworkACL UpdateNetworkAddressSet UpdateNetworkIntegration UpdateNetworkZone UpdateNetworkZoneRecord UpdateNetwork UpdateNetworkForward UpdateNetworkLoadBalancer UpdateNetworkPeer
               GetAPIVersions GetCertificateFingerprints GetCertificate GetCluster GetClusterGroups GetClusterGroup GetClusterMemberNames GetClusterMember GetClusterMemberState GetMetadataConfiguration GetProjectAccess GetProjectState GetServerResources GetWarningUUIDs GetWarning
               UpdateServer CreateCertificate UpdateCertificate DeleteCertificate UpdateCluster UpdateClusterCertificate CreateClusterGroup RenameClusterGroup UpdateClusterGroup DeleteClusterGroup CreateClusterMember RenameClusterMember UpdateClusterMember DeleteClusterMember UpdateClusterMemberState CreateProfile RenameProfile UpdateProfile DeleteProfile CreateProject RenameProject UpdateProject DeleteProject UpdateWarning DeleteWarning
               PatchServer PatchCertificate PatchClusterGroup PatchClusterMember PatchImageAlias PatchInstanceMetadata PatchWarning)
             )

    assert Enum.frequencies_by(@manifest["entries"], & &1["status"]) == %{
             "partial" => 2,
             "complete" => 133
           }

    coverage = Jason.decode!(File.read!("priv/incus/coverage.json"))
    assert coverage["endpoint_evidence"] == "priv/incus/endpoint-evidence.json"
    assert coverage["complete_port"] == false

    assert Enum.frequencies_by(coverage["entries"], & &1["status"]) == %{
             "partial" => 1239,
             "missing" => 41
           }
  end

  test "rejects incomplete or overclaimed inspection contracts", %{native: native} do
    path = ["fixture_contracts", "initial_inspection_v1"]

    for {field, value} <- [
          {"methods", ["GetProject"]},
          {"cases", ["populated"]},
          {"transports", ["unix"]},
          {"evidence", []},
          {"status", "complete"},
          {"queries", "all"},
          {"volume_types", ["all"]}
        ] do
      changed = put_in(@manifest, path ++ [field], value)

      assert_raise ExUnit.AssertionError, ~r/inspection contract/, fn ->
        EndpointEvidence.validate!(changed, native)
      end
    end

    [first | rest] = @manifest["entries"]

    for changed <- [
          put_in(@manifest, ["fixture_contracts", "unsupported"], %{"status" => "complete"}),
          %{
            @manifest
            | "entries" => [Map.put(first, "verified_scope", "initial_inspection_v1") | rest]
          }
        ] do
      assert_raise ExUnit.AssertionError, ~r/inspection contract/, fn ->
        EndpointEvidence.validate!(changed, native)
      end
    end

    entries = Enum.map(@manifest["entries"], &Map.delete(&1, "verified_scope"))

    assert_raise ExUnit.AssertionError, ~r/inspection contract/, fn ->
      EndpointEvidence.validate!(%{@manifest | "entries" => entries}, native)
    end

    assert_raise ExUnit.AssertionError, ~r/inspection contract/, fn ->
      EndpointEvidence.validate!(Map.delete(@manifest, "fixture_contracts"), native)
    end
  end

  test "shared-source anchors stay distinct and source is fresh across validations", %{
    native: native
  } do
    root = Path.join(System.tmp_dir!(), "op-evidence-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    path = Path.join(root, "anchors.exs")
    first = ~s(test "first anchor" do :ok end)
    second = ~s(test "second anchor" do :ok end)
    File.write!(path, first <> "\n" <> second)

    manifest =
      @manifest
      |> put_in(["evidence", "core_inspection_contract"], [path, "first anchor"])
      |> put_in(["evidence", "receive_expiry"], [path, "second anchor"])

    assert :ok = EndpointEvidence.validate!(manifest, native)
    File.write!(path, first)

    assert_raise ExUnit.AssertionError, ~r/missing test anchor/, fn ->
      EndpointEvidence.validate!(manifest, native)
    end
  end

  test "rejects incomplete or overclaimed core inspection contracts", %{native: native} do
    path = ["fixture_contracts", "core_inspection_v1"]

    for field <-
          ~w(methods helpers queries instance_types discovery transports cases evidence status) do
      assert_raise ExUnit.AssertionError, ~r/inspection contract/, fn ->
        EndpointEvidence.validate!(put_in(@manifest, path ++ [field], nil), native)
      end
    end

    for row <- @manifest["entries"],
        row["verified_scope"] == "core_inspection_v1",
        key <- ~w(core_inspection_contract receive_expiry) do
      entries =
        Enum.map(@manifest["entries"], fn entry ->
          if entry == row,
            do: %{entry | "evidence" => entry["evidence"] -- [key]},
            else: entry
        end)

      assert_raise ExUnit.AssertionError, ~r/inspection contract/, fn ->
        EndpointEvidence.validate!(%{@manifest | "entries" => entries}, native)
      end
    end
  end

  test "rejects incomplete or overclaimed mutation lifecycle contracts", %{native: native} do
    path = ["fixture_contracts", "initial_mutation_lifecycle_v1"]

    for field <-
          ~w(methods cases async_cases cancel_cases evidence transports bodies queries status) do
      changed = put_in(@manifest, path ++ [field], nil)

      assert_raise ExUnit.AssertionError, ~r/mutation contract/, fn ->
        EndpointEvidence.validate!(changed, native)
      end
    end

    for row <- Enum.filter(@manifest["entries"], &(&1["backlog"] == "B01")) do
      entries =
        Enum.map(@manifest["entries"], fn entry ->
          if entry == row,
            do: %{entry | "evidence" => entry["evidence"] -- ["mutation_lifecycle"]},
            else: entry
        end)

      assert_raise ExUnit.AssertionError, ~r/mutation contract/, fn ->
        EndpointEvidence.validate!(%{@manifest | "entries" => entries}, native)
      end
    end
  end

  test "reviewed completion records gate every completed row and certified stream", %{
    native: native
  } do
    audit = Jason.decode!(File.read!("priv/incus/endpoint-inventory.json"))
    assert :ok = EndpointInventory.validate!(audit, native)

    assert audit["entries"]
           |> Enum.filter(& &1["behavior_complete"])
           |> Enum.map(&{&1["pair"], &1["completion_record"]}) == [
             {"DELETE /1.0/certificates/{}", "b10_delete_certificates_one_v1"},
             {"DELETE /1.0/cluster/groups/{}", "b10_delete_cluster_groups_one_v1"},
             {"DELETE /1.0/cluster/members/{}", "b10_delete_cluster_members_one_v1"},
             {"DELETE /1.0/images/{}", "b01_delete_image_v1"},
             {"DELETE /1.0/instances/{}", "b01_delete_instance_v1"},
             {"DELETE /1.0/instances/{}/snapshots/{}", "b01_delete_instance_snapshot_v1"},
             {"DELETE /1.0/network-acls/{}", "b09_delete_network_acls_one_v1"},
             {"DELETE /1.0/network-address-sets/{}", "b09_delete_network_address_sets_one_v1"},
             {"DELETE /1.0/network-integrations/{}", "b09_delete_network_integrations_one_v1"},
             {"DELETE /1.0/network-zones/{}", "b09_delete_network_zones_one_v1"},
             {"DELETE /1.0/network-zones/{}/records/{}",
              "b09_delete_network_zones_one_records_one_v1"},
             {"DELETE /1.0/networks/{}", "b09_delete_networks_one_v1"},
             {"DELETE /1.0/networks/{}/forwards/{}", "b09_delete_networks_one_forwards_one_v1"},
             {"DELETE /1.0/networks/{}/load-balancers/{}",
              "b09_delete_networks_one_load_balancers_one_v1"},
             {"DELETE /1.0/networks/{}/peers/{}", "b09_delete_networks_one_peers_one_v1"},
             {"DELETE /1.0/operations/{}", "b01_cancel_operation_v1"},
             {"DELETE /1.0/profiles/{}", "b10_delete_profiles_one_v1"},
             {"DELETE /1.0/projects/{}", "b10_delete_projects_one_v1"},
             {"DELETE /1.0/warnings/{}", "b10_delete_warnings_one_v1"},
             {"GET /", "b10_root_v1"},
             {"GET /1.0", "b02_discovery_v1"},
             {"GET /1.0/certificates", "b10_certificates_v1"},
             {"GET /1.0/certificates/{}", "b10_certificates_one_v1"},
             {"GET /1.0/cluster", "b10_cluster_v1"},
             {"GET /1.0/cluster/groups", "b10_cluster_groups_v1"},
             {"GET /1.0/cluster/groups/{}", "b10_cluster_groups_one_v1"},
             {"GET /1.0/cluster/members", "b10_cluster_members_v1"},
             {"GET /1.0/cluster/members/{}", "b10_cluster_members_one_v1"},
             {"GET /1.0/cluster/members/{}/state", "b10_cluster_members_one_state_v1"},
             {"GET /1.0/events", "b03_events_v1"},
             {"GET /1.0/images", "b02_images_v1"},
             {"GET /1.0/images/{}", "b02_image_v1"},
             {"GET /1.0/instances", "b02_instances_v1"},
             {"GET /1.0/instances/{}", "b02_instance_v1"},
             {"GET /1.0/instances/{}/snapshots", "b02_instance_snapshots_v1"},
             {"GET /1.0/instances/{}/snapshots/{}", "b02_instance_snapshot_v1"},
             {"GET /1.0/instances/{}/state", "b02_instance_state_v1"},
             {"GET /1.0/metadata/configuration", "b10_metadata_configuration_v1"},
             {"GET /1.0/network-acls", "b09_network_acls_v1"},
             {"GET /1.0/network-acls/{}", "b09_network_acls_one_v1"},
             {"GET /1.0/network-address-sets", "b09_network_address_sets_v1"},
             {"GET /1.0/network-address-sets/{}", "b09_network_address_sets_one_v1"},
             {"GET /1.0/network-allocations", "b09_network_allocations_v1"},
             {"GET /1.0/network-integrations", "b09_network_integrations_v1"},
             {"GET /1.0/network-integrations/{}", "b09_network_integrations_one_v1"},
             {"GET /1.0/network-zones", "b09_network_zones_v1"},
             {"GET /1.0/network-zones/{}", "b09_network_zones_one_v1"},
             {"GET /1.0/network-zones/{}/records", "b09_network_zones_one_records_v1"},
             {"GET /1.0/network-zones/{}/records/{}", "b09_network_zones_one_records_one_v1"},
             {"GET /1.0/networks", "b02_networks_v1"},
             {"GET /1.0/networks/{}", "b02_network_v1"},
             {"GET /1.0/networks/{}/forwards", "b09_networks_one_forwards_v1"},
             {"GET /1.0/networks/{}/forwards/{}", "b09_networks_one_forwards_one_v1"},
             {"GET /1.0/networks/{}/leases", "b09_networks_one_leases_v1"},
             {"GET /1.0/networks/{}/load-balancers", "b09_networks_one_load_balancers_v1"},
             {"GET /1.0/networks/{}/load-balancers/{}", "b09_networks_one_load_balancers_one_v1"},
             {"GET /1.0/networks/{}/load-balancers/{}/state",
              "b09_networks_one_load_balancers_one_state_v1"},
             {"GET /1.0/networks/{}/peers", "b09_networks_one_peers_v1"},
             {"GET /1.0/networks/{}/peers/{}", "b09_networks_one_peers_one_v1"},
             {"GET /1.0/networks/{}/state", "b09_networks_one_state_v1"},
             {"GET /1.0/operations", "b02_operations_v1"},
             {"GET /1.0/operations/{}", "b02_operation_v1"},
             {"GET /1.0/operations/{}/wait", "b03_native_wait_v1"},
             {"GET /1.0/profiles", "b02_profiles_v1"},
             {"GET /1.0/profiles/{}", "b02_profile_v1"},
             {"GET /1.0/projects", "b02_projects_v1"},
             {"GET /1.0/projects/{}", "b02_project_v1"},
             {"GET /1.0/projects/{}/access", "b10_projects_one_access_v1"},
             {"GET /1.0/projects/{}/state", "b10_projects_one_state_v1"},
             {"GET /1.0/resources", "b10_resources_v1"},
             {"GET /1.0/storage-pools", "b02_storage_pools_v1"},
             {"GET /1.0/storage-pools/{}", "b02_storage_pool_v1"},
             {"GET /1.0/storage-pools/{}/volumes", "b02_storage_volumes_v1"},
             {"GET /1.0/storage-pools/{}/volumes/{}/{}", "b02_storage_volume_v1"},
             {"GET /1.0/warnings", "b10_warnings_v1"},
             {"GET /1.0/warnings/{}", "b10_warnings_one_v1"},
             {"PATCH /1.0", "b05_patch_server_v1"},
             {"PATCH /1.0/certificates/{}", "b05_patch_certificates_one_v1"},
             {"PATCH /1.0/cluster/groups/{}", "b05_patch_cluster_groups_one_v1"},
             {"PATCH /1.0/cluster/members/{}", "b05_patch_cluster_members_one_v1"},
             {"PATCH /1.0/images/aliases/{}", "b05_patch_images_aliases_one_v1"},
             {"PATCH /1.0/images/{}", "b05_patch_images_one_v1"},
             {"PATCH /1.0/instances/{}", "b04_instance_patch_v1"},
             {"PATCH /1.0/instances/{}/metadata", "b05_patch_instances_one_metadata_v1"},
             {"PATCH /1.0/instances/{}/snapshots/{}", "b05_patch_instances_one_snapshots_one_v1"},
             {"PATCH /1.0/profiles/{}", "b05_patch_profiles_one_v1"},
             {"PATCH /1.0/projects/{}", "b05_patch_projects_one_v1"},
             {"PATCH /1.0/warnings/{}", "b05_patch_warnings_one_v1"},
             {"POST /1.0/certificates", "b10_post_certificates_v1"},
             {"POST /1.0/cluster/groups", "b10_post_cluster_groups_v1"},
             {"POST /1.0/cluster/groups/{}", "b10_post_cluster_groups_one_v1"},
             {"POST /1.0/cluster/members", "b10_post_cluster_members_v1"},
             {"POST /1.0/cluster/members/{}", "b10_post_cluster_members_one_v1"},
             {"POST /1.0/cluster/members/{}/state", "b10_post_cluster_members_one_state_v1"},
             {"POST /1.0/instances/{}/exec", "b03_exec_v1"},
             {"POST /1.0/instances/{}/snapshots", "b01_create_instance_snapshot_v1"},
             {"POST /1.0/network-acls", "b09_post_network_acls_v1"},
             {"POST /1.0/network-acls/{}", "b09_post_network_acls_one_v1"},
             {"POST /1.0/network-address-sets", "b09_post_network_address_sets_v1"},
             {"POST /1.0/network-address-sets/{}", "b09_post_network_address_sets_one_v1"},
             {"POST /1.0/network-integrations", "b09_post_network_integrations_v1"},
             {"POST /1.0/network-integrations/{}", "b09_post_network_integrations_one_v1"},
             {"POST /1.0/network-zones", "b09_post_network_zones_v1"},
             {"POST /1.0/network-zones/{}/records", "b09_post_network_zones_one_records_v1"},
             {"POST /1.0/networks", "b09_post_networks_v1"},
             {"POST /1.0/networks/{}", "b09_post_networks_one_v1"},
             {"POST /1.0/networks/{}/forwards", "b09_post_networks_one_forwards_v1"},
             {"POST /1.0/networks/{}/load-balancers", "b09_post_networks_one_load_balancers_v1"},
             {"POST /1.0/networks/{}/peers", "b09_post_networks_one_peers_v1"},
             {"POST /1.0/profiles", "b10_post_profiles_v1"},
             {"POST /1.0/profiles/{}", "b10_post_profiles_one_v1"},
             {"POST /1.0/projects", "b10_post_projects_v1"},
             {"POST /1.0/projects/{}", "b10_post_projects_one_v1"},
             {"PUT /1.0", "b10_put_server_v1"},
             {"PUT /1.0/certificates/{}", "b10_put_certificates_one_v1"},
             {"PUT /1.0/cluster", "b10_put_cluster_v1"},
             {"PUT /1.0/cluster/certificate", "b10_put_cluster_certificate_v1"},
             {"PUT /1.0/cluster/groups/{}", "b10_put_cluster_groups_one_v1"},
             {"PUT /1.0/cluster/members/{}", "b10_put_cluster_members_one_v1"},
             {"PUT /1.0/instances/{}", "b01_update_instance_v1"},
             {"PUT /1.0/instances/{}/state", "b01_update_instance_state_v1"},
             {"PUT /1.0/network-acls/{}", "b09_put_network_acls_one_v1"},
             {"PUT /1.0/network-address-sets/{}", "b09_put_network_address_sets_one_v1"},
             {"PUT /1.0/network-integrations/{}", "b09_put_network_integrations_one_v1"},
             {"PUT /1.0/network-zones/{}", "b09_put_network_zones_one_v1"},
             {"PUT /1.0/network-zones/{}/records/{}", "b09_put_network_zones_one_records_one_v1"},
             {"PUT /1.0/networks/{}", "b09_put_networks_one_v1"},
             {"PUT /1.0/networks/{}/forwards/{}", "b09_put_networks_one_forwards_one_v1"},
             {"PUT /1.0/networks/{}/load-balancers/{}",
              "b09_put_networks_one_load_balancers_one_v1"},
             {"PUT /1.0/networks/{}/peers/{}", "b09_put_networks_one_peers_one_v1"},
             {"PUT /1.0/profiles/{}", "b10_put_profiles_one_v1"},
             {"PUT /1.0/projects/{}", "b10_put_projects_one_v1"},
             {"PUT /1.0/warnings/{}", "b10_put_warnings_one_v1"}
           ]

    assert for(%{"status" => "certified", "id" => id} <- audit["stream_contracts"], do: id) ==
             ["S01", "S03"]

    refute audit["behavior_complete"] or audit["complete_port"]
    wait = ["completion_records", "b03_native_wait_v1"]
    update = ["completion_records", "b01_update_instance_v1"]
    delete = ["completion_records", "b01_delete_image_v1"]
    cancel = ["completion_records", "b01_cancel_operation_v1"]
    patch = ["completion_records", "b04_instance_patch_v1"]
    instances = ["completion_records", "b02_instances_v1"]
    images = ["completion_records", "b02_images_v1"]
    discovery = ["completion_records", "b02_discovery_v1"]
    network_update = ["completion_records", "b09_put_networks_one_v1"]
    peer_create = ["completion_records", "b09_post_networks_one_peers_v1"]
    certificates = ["completion_records", "b10_post_certificates_v1"]
    cluster_update = ["completion_records", "b10_put_cluster_v1"]
    server_patch = ["completion_records", "b05_patch_server_v1"]
    snapshot_patch = ["completion_records", "b05_patch_instances_one_snapshots_one_v1"]
    events = ["completion_records", "b03_events_v1"]
    socket = Enum.find(audit["entries"], &(&1["pair"] == "GET /1.0/operations/{}/websocket"))
    head = Enum.find(audit["entries"], &(&1["pair"] == "HEAD /1.0/instances/{}/files"))

    complete = fn row, record ->
      entries =
        Enum.map(audit["entries"], fn entry ->
          if entry == row,
            do: Map.merge(entry, %{"behavior_complete" => true, "completion_record" => record}),
            else: entry
        end)

      %{audit | "entries" => entries}
    end

    for {changed, message} <- [
          {update_in(audit, wait ++ ["cases"], &Map.delete(&1, "native_404")),
           "missing completion case"},
          {put_in(audit, wait ++ ["cases", "invented"], ["native_wait"]),
           "missing completion case"},
          {put_in(audit, wait ++ ["transports"], ["unix"]), "missing completion transport"},
          {put_in(audit, events ++ ["cases", "native_403"], []), "missing completion evidence"},
          {put_in(audit, events ++ ["evidence_kinds", "event_rejection"], "proxy_success"),
           "unknown completion evidence kind"},
          {update_in(audit, wait ++ ["evidence_kinds"], &Map.delete(&1, "native_wait_preflight")),
           "stale completion evidence kinds"},
          {put_in(audit, wait ++ ["excluded_views"], %{}), "unlisted completion view"},
          {put_in(
             audit,
             wait ++ ["excluded_views", "GET /1.0/operations/{id}/wait?public", "approved"],
             nil
           ), "unapproved exclusion"},
          {update_in(audit, wait ++ ["excluded_scope"], &[%{"scope" => "unapproved"} | &1]),
           "unapproved exclusion"},
          {update_in(audit, events ++ ["selectors"], &Map.delete(&1, "type")),
           "unclassified completion selector"},
          {put_in(audit, events ++ ["selectors", "type"], nil),
           "unclassified completion selector"},
          {put_in(audit, events ++ ["selectors", "type"], ""),
           "unclassified completion selector"},
          {put_in(audit, wait ++ ["methods"], ["GetOperationWait"]), "stale completion methods"},
          {put_in(audit, wait ++ ["approved"], nil), "unapproved completion record"},
          {put_in(audit, wait ++ ["rows"], ["GET /1.0/operations/{}/wait", socket["pair"]]),
           "unrelated completion record row"},
          {complete.(socket, "b03_native_wait_v1"), "unsupported completion claim"},
          {complete.(head, "b03_native_wait_v1"), "unsupported completion claim"},
          {update_in(audit, ["stream_contracts"], fn contracts ->
             Enum.map(contracts, fn contract ->
               if contract["id"] == "S03",
                 do: Map.merge(contract, %{"status" => "open_contract_certification"}),
                 else: contract
             end)
           end), "open linked stream contract"},
          {update_in(audit, ["stream_contracts"], fn contracts ->
             Enum.map(contracts, fn contract ->
               if contract["id"] == "S02",
                 do: %{contract | "status" => "certified"},
                 else: contract
             end)
           end), "unsupported certification claim"},
          {update_in(audit, update ++ ["cases"], &Map.delete(&1, "extension_guards")),
           "missing completion case"},
          {update_in(audit, update ++ ["cases"], &Map.delete(&1, "etag")),
           "missing completion case"},
          {update_in(
             audit,
             ["completion_records", "b03_exec_v1", "cases"],
             &Map.delete(&1, "body_fields")
           ), "missing completion case"},
          {update_in(audit, patch ++ ["cases"], &Map.delete(&1, "unconditional_rejection")),
           "missing completion case"},
          {put_in(audit, delete ++ ["cases", "native_404"], ["mutation_guards"])
           |> put_in(delete ++ ["evidence_kinds", "mutation_guards"], "named_go_differential"),
           "unlinked completion evidence"},
          {put_in(audit, patch ++ ["excluded_scope"], [%{"scope" => "unconditional PATCH"}]),
           "unapproved exclusion"},
          {put_in(audit, cancel ++ ["kind"], "async_mutation"), "missing completion case"},
          {update_in(audit, instances ++ ["cases"], &Map.delete(&1, "selectors")),
           "missing completion case"},
          {update_in(audit, images ++ ["cases"], &Map.delete(&1, "extension_guards")),
           "missing completion case"},
          {update_in(audit, discovery ++ ["cases"], &Map.delete(&1, "discovery_version")),
           "missing completion case"},
          {put_in(audit, images ++ ["excluded_views", "GET /1.0/images?public", "approved"], nil),
           "unapproved exclusion"},
          {update_in(audit, instances ++ ["selectors"], &Map.delete(&1, "filter")),
           "unclassified completion selector"},
          {update_in(audit, instances ++ ["methods"], &List.delete(&1, "GetInstancesFull")),
           "stale completion methods"},
          {update_in(audit, network_update ++ ["cases"], &Map.delete(&1, "native_409")),
           "missing completion case"},
          {update_in(audit, network_update ++ ["cases"], &Map.delete(&1, "etag")),
           "missing completion case"},
          {update_in(audit, peer_create ++ ["evidence_kinds"], &Map.delete(&1, "peer_guard")),
           "stale completion evidence kinds"},
          {put_in(audit, network_update ++ ["kind"], "read_contract"), "missing completion case"},
          # A synchronous record with an operation-returning method proves its lifecycle.
          {update_in(audit, certificates ++ ["cases"], &Map.delete(&1, "running")),
           "missing completion case"},
          {update_in(audit, certificates ++ ["methods"], &(&1 -- ["CreateCertificateToken"])),
           "stale completion methods"},
          {update_in(
             audit,
             cluster_update ++ ["evidence_kinds"],
             &Map.delete(&1, "admin_guards")
           ), "stale completion evidence kinds"},
          # A conditional PATCH proves its own result kind: empty sync or accepted /wait.
          {update_in(audit, server_patch ++ ["cases"], &Map.delete(&1, "empty_sync")),
           "missing completion case"},
          {update_in(audit, snapshot_patch ++ ["cases"], &Map.delete(&1, "running")),
           "missing completion case"},
          {update_in(
             audit,
             server_patch ++ ["cases"],
             &Map.put(&1, "restore_rejection", ["rest_patch"])
           ), "missing completion case"},
          {%{audit | "behavior_complete" => true}, ""},
          {%{audit | "complete_port" => true}, ""}
        ] do
      assert_raise ExUnit.AssertionError, ~r/#{message}/, fn ->
        EndpointInventory.validate!(changed, native)
      end
    end

    # A completed row whose linked stream contract is still open cannot complete.
    record = get_in(audit, events)

    shared =
      Map.merge(socket, %{"behavior_complete" => true, "completion_record" => "b03_events_v1"})

    changed =
      audit
      |> put_in(events ++ ["rows"], record["rows"] ++ [socket["pair"]])
      |> Map.update!("entries", fn entries ->
        Enum.map(entries, &if(&1 == socket, do: shared, else: &1))
      end)

    assert_raise ExUnit.AssertionError, ~r/open linked stream contract/, fn ->
      EndpointInventory.validate!(changed, native)
    end

    # Instance creation stays partial while its archive and migration contracts are open.
    create = Enum.find(audit["entries"], &(&1["pair"] == "POST /1.0/instances"))
    record = get_in(audit, update)

    changed =
      audit
      |> put_in(update ++ ["rows"], record["rows"] ++ [create["pair"]])
      |> put_in(update ++ ["methods"], record["methods"] ++ ["CreateInstance"])
      |> Map.update!("entries", fn entries ->
        Enum.map(
          entries,
          &if(&1 == create,
            do:
              Map.merge(create, %{
                "behavior_complete" => true,
                "completion_record" => "b01_update_instance_v1"
              }),
            else: &1
          )
        )
      end)

    assert_raise ExUnit.AssertionError, ~r/open linked stream contract/, fn ->
      EndpointInventory.validate!(changed, native)
    end

    # Selected rows cannot drop or claim completion independently of the full ledger.
    for {verb, pair, status} <- [
          {"GET", "/1.0/operations/{id}/wait", "partial"},
          {"POST", "/1.0/instances", "complete"}
        ] do
      entries =
        Enum.map(@manifest["entries"], fn row ->
          if row["path"] == pair and row["verb"] == verb,
            do: %{row | "status" => status},
            else: row
        end)

      assert_raise ExUnit.AssertionError, ~r/unsupported completion claim/, fn ->
        EndpointEvidence.validate!(%{@manifest | "entries" => entries}, native)
      end
    end
  end

  test "exec completion certifies S01 only with its full mode, failure and transport evidence", %{
    native: native
  } do
    audit = Jason.decode!(File.read!("priv/incus/endpoint-inventory.json"))
    exec = ["completion_records", "b03_exec_v1"]
    record = get_in(audit, exec)
    assert record["kind"] == "live_exec" and record["stream_contracts"] == ["S01"]
    assert record["methods"] == ["ExecInstance"] and record["transports"] == ~w(unix mutual_https)

    assert Enum.sort(for {key, "named_go_differential"} <- record["evidence_kinds"], do: key) ==
             ~w(exec_guards exec_modes exec_native exec_rejection)

    s01 = Enum.find(audit["stream_contracts"], &(&1["id"] == "S01"))
    assert s01["boundary"] =~ "interactive host-owned channels"

    reopen = fn status, record_id ->
      update_in(audit, ["stream_contracts"], fn contracts ->
        Enum.map(contracts, fn contract ->
          if contract["id"] == "S01",
            do: Map.merge(contract, %{"status" => status, "completion_record" => record_id}),
            else: contract
        end)
      end)
    end

    for {changed, message} <- [
          {update_in(audit, exec ++ ["cases"], &Map.delete(&1, "control_range")),
           "missing completion case"},
          {update_in(audit, exec ++ ["cases"], &Map.delete(&1, "extension_guards")),
           "missing completion case"},
          {put_in(audit, exec ++ ["transports"], ["unix"]), "missing completion transport"},
          {put_in(audit, exec ++ ["cases", "interactive"], []), "missing completion evidence"},
          {put_in(audit, exec ++ ["evidence_kinds", "exec_modes"], "raw_proxy_success"),
           "unknown completion evidence kind"},
          {update_in(audit, exec ++ ["evidence_kinds"], &Map.delete(&1, "exec_collector")),
           "stale completion evidence kinds"},
          {put_in(audit, exec ++ ["selectors"], %{"target" => "host_routing"}),
           "unclassified completion selector"},
          {put_in(audit, exec ++ ["excluded_scope"], [%{"scope" => "recorded output"}]),
           "unapproved exclusion"},
          {put_in(audit, exec ++ ["approved_differences"], [%{"difference" => "unreviewed"}]),
           "unapproved exclusion"},
          {put_in(audit, exec ++ ["methods"], ["ExecInstance", "GetInstanceFile"]),
           "stale completion methods"},
          {reopen.("open_contract_certification", nil), "open linked stream contract"},
          {reopen.("certified", "b03_events_v1"), "unsupported certification claim"}
        ] do
      assert_raise ExUnit.AssertionError, ~r/#{message}/, fn ->
        EndpointInventory.validate!(changed, native)
      end
    end

    selected = fn update ->
      entries =
        Enum.map(@manifest["entries"], fn row ->
          if row["method"] == "ExecInstance", do: update.(row), else: row
        end)

      %{@manifest | "entries" => entries}
    end

    # Selected evidence must still link every record evidence key and the completion.
    root = Path.join(System.tmp_dir!(), "op-exec-record-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    path = Path.join(root, "endpoint-evidence.json")
    unlinked = selected.(&Map.update!(&1, "evidence", fn keys -> keys -- ["exec_guards"] end))
    File.write!(path, Jason.encode!(unlinked))
    audit = %{audit | "selected_evidence" => path}

    assert_raise ExUnit.AssertionError, ~r/unlinked completion evidence/, fn ->
      EndpointInventory.validate!(audit, native)
    end

    for {update, message} <- [
          {&%{&1 | "status" => "partial"}, "unsupported completion claim"},
          {&Map.delete(&1, "completion_record"), "unsupported completion claim"}
        ] do
      assert_raise ExUnit.AssertionError, ~r/#{message}/, fn ->
        EndpointEvidence.validate!(selected.(update), native)
      end
    end
  end

  test "rejects removed native secret-wait variants", %{native: native} do
    wait = Enum.find(@manifest["entries"], &(&1["method"] == "GetOperationWait"))

    for removed <- [Map.delete(wait, "variants"), %{wait | "variants" => []}] do
      entries = Enum.map(@manifest["entries"], &if(&1 == wait, do: removed, else: &1))

      assert_raise ExUnit.AssertionError, ~r/missing native secret-wait variant/, fn ->
        EndpointEvidence.validate!(%{@manifest | "entries" => entries}, native)
      end
    end
  end

  for {field, value, message} <- [
        {"reference_revision", "stale", "stale reference"},
        {"source", %{}, "stale REST source"},
        {"inventory_complete", true, "false"},
        {"complete_port", true, "false"}
      ] do
    test "rejects misleading or stale #{field}", %{native: native} do
      assert_raise ExUnit.AssertionError, ~r/#{unquote(message)}/, fn ->
        EndpointEvidence.validate!(
          Map.put(@manifest, unquote(field), unquote(Macro.escape(value))),
          native
        )
      end
    end
  end

  test "rejects duplicate pairs, missing links, misplaced methods and unsupported completion", %{
    native: native
  } do
    [first, second | rest] = @manifest["entries"]

    for {row, message} <- [
          {first, "duplicate endpoint pair"},
          {%{second | "method" => "AbsentMethod"}, "missing catalogue method"},
          {%{second | "method" => "GetImage"}, "method/endpoint mismatch"},
          {Map.put(second, "variants", ["GetImage"]), "method/endpoint mismatch"},
          {%{second | "clients" => ["absent"]}, "missing client link"},
          {%{second | "evidence" => ["absent"]}, "missing evidence link"},
          {Map.delete(%{second | "status" => "complete"}, "completion_record"),
           "unsupported completion claim"},
          {%{second | "gaps" => []}, "missing gaps"},
          {%{second | "path" => "/1.0/not-a-route"}, "missing native endpoint"}
        ] do
      assert_raise ExUnit.AssertionError, ~r/#{message}/, fn ->
        EndpointEvidence.validate!(%{@manifest | "entries" => [first, row | rest]}, native)
      end
    end

    evidence =
      Map.put(@manifest["evidence"], "typed", ["test/resource_slice_test.exs", "absent test"])

    assert_raise ExUnit.AssertionError, ~r/missing test anchor/, fn ->
      EndpointEvidence.validate!(%{@manifest | "evidence" => evidence}, native)
    end
  end
end
