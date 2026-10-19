"""Regenerate evidence mappings; never upgrade a fixture slice to full parity."""
import json
from pathlib import Path
root = Path(__file__).resolve().parents[1]
def load(path): return json.loads((root/path).read_text())
inv = load('priv/incus/inventory.json')
methods = {m['name']: m for m in load('priv/incus/methods.json')['methods']}
models = {m[key] for m in methods.values() for key in ['body','model'] if m[key]}
constants = load('priv/incus/constants.json')['values']
helpers = {
 'RawQuery': ('lib/opsmaru/incus.ex', ['test/client_test.exs','test/reference_wire_test.exs','test/instance_patch_test.exs','test/inspection_contract_test.exs']),
 'UseProject': ('lib/opsmaru/incus.ex',['test/resource_slice_test.exs']),
 'UseTarget': ('lib/opsmaru/incus.ex',['test/resource_slice_test.exs']),
 'HasExtension': ('lib/opsmaru/incus.ex',['test/client_test.exs']),
 'CheckExtension': ('lib/opsmaru/incus.ex',['test/client_test.exs']),
 'GetServer': ('lib/opsmaru/incus.ex',['test/client_test.exs','test/inspection_contract_test.exs']),
}
for name in ['GetImageFile','GetImageAliasType','GetImageAliasArchitectures','GetImageSecret','CopyImage']:
 helpers[name]=('lib/opsmaru/incus/images.ex',['test/image_transfer_test.exs'])
for name in ['GetInstanceFile','CreateInstanceFile','CreateInstanceFromBackup']:
 helpers[name]=('lib/opsmaru/incus/files.ex',['test/file_reference_test.exs'])
for name in ['GetInstanceFileSFTPConn','GetInstanceNBDConn']:
 helpers[name]=('lib/opsmaru/incus/raw_channel.ex',['test/raw_channel_test.exs','test/native_upgrade_reference_test.exs','test/tls_stream_test.exs'])
sftp_helpers = ['GetInstanceFileSFTP','GetStoragePoolVolumeFileSFTP']
for name in ['RawWebsocket','GetOperationWebsocket']:
 helpers[name]=('lib/opsmaru/incus/web_socket.ex',['test/web_socket_test.exs','test/tls_stream_test.exs'])
event_subscriptions = ['GetEvents','GetEventsByType','GetEventsAllProjects','GetEventsAllProjectsByType']
for name in ['operation.Wait','operation.Cancel','operation.Get']:
 helpers[name]=('lib/opsmaru/incus/operation.ex',['test/operation_test.exs'])
for name in ['ConnectIncus','ConnectIncusUnix','ConnectIncusWithContext','ConnectIncusUnixWithContext','ProtocolIncus.WithContext','ProtocolIncus.Disconnect']:
 helpers[name]=('lib/opsmaru/incus.ex',['test/request_context_test.exs'])
for name in ['operation.Refresh','operation.WaitContext','Operation.Get','Operation.Refresh','Operation.Wait','Operation.WaitContext','Operation.Cancel']:
 helpers[name]=('lib/opsmaru/incus/operation.ex',['test/request_context_test.exs','test/operation_test.exs'])
for name in ['operation.GetWebsocket','Operation.GetWebsocket']:
 helpers[name]=('lib/opsmaru/incus/operation.ex',['test/session_test.exs','test/request_context_test.exs'])
for name in ['CopyInstance','CopyInstanceSnapshot','CopyStoragePoolVolume']:
 helpers[name]=('lib/opsmaru/incus/copy.ex',['test/copy_test.exs','test/migration_test.exs'])
helpers['CopyInstance'][1].append('test/copy_guards_test.exs')
for name in ['GetMetrics','GetNetworkACLLogfile','GetInstanceLogfile','GetInstanceConsoleLog','GetInstanceTemplateFile','CreateInstanceTemplateFile','GetInstanceDebugMemory']:
 helpers[name]=('lib/opsmaru/incus/streams.ex',['test/streams_test.exs'])
for name in ['CopyInstance','CopyInstanceSnapshot','CopyStoragePoolVolume','MoveStoragePoolVolume']:
 helpers.setdefault(name, ('lib/opsmaru/incus/copy.ex', []))[1].append('test/copy_negotiation_reference_test.exs')
for name in ['CreateInstanceFromImage','RebuildInstanceFromImage']:
 helpers[name]=('lib/opsmaru/incus/image_instances.ex',['test/copy_negotiation_reference_test.exs'])
for name in ['operation.Cancel','Operation.Cancel']:
 helpers[name][1].append('test/mutation_lifecycle_test.exs')
helpers['RawOperation']=('lib/opsmaru/incus/operation.ex',['test/raw_operation_reference_test.exs'])
writable_types = 'Certificate ClusterMember ClusterGroup Image Instance InstanceSnapshot Network NetworkACL NetworkAddressSet NetworkForward NetworkIntegration NetworkLoadBalancer NetworkPeer NetworkZone NetworkZoneRecord Profile Project Server StoragePool StorageBucket StorageBucketKey StorageVolume StorageVolumeSnapshot'.split()
for name in writable_types:
 helpers[name+'.Writable']=('lib/opsmaru/incus/model.ex',['test/model_helpers_reference_test.exs'])
models.update(writable_types)
models.update(name+'Put' for name in writable_types)
models.add('StatusCode')
helpers['Instance.IsActive']=('lib/opsmaru/incus/model.ex',['test/model_helpers_reference_test.exs'])
for name in ['NetworkForward','NetworkLoadBalancer','NetworkPeer','StorageBucket','StorageBucketKey']:
 helpers[name+'.Etag']=('lib/opsmaru/incus/model.ex',['test/model_helpers_reference_test.exs'])
for name in ['Certificate','Image','Instance','NetworkACL','Profile','Project','StorageBucket','StorageBucketKey','StorageVolume']:
 helpers[name+'.URL']=('lib/opsmaru/incus/model_url.ex',['test/model_helpers_reference_test.exs'])
helpers['GetParentAndSnapshotName']=('lib/opsmaru/incus/model_url.ex',['test/model_helpers_reference_test.exs'])
for name in ['NewURL','URL.Scheme','URL.Host','URL.Path','URL.Project','URL.Target','URL.WithQuery','URL.Fragment']:
 helpers[name]=('lib/opsmaru/incus/url.ex',['test/url_reference_test.exs'])
for name in ['GetConnectionInfo','IsClustered','IsAgent','RequireAuthenticated']:
 helpers[name]=('lib/opsmaru/incus/discovery.ex',['test/discovery_helpers_test.exs','test/authenticated_header_test.exs'])
for name in ['GetTarget','CancelTarget']:
 helpers[name]=('lib/opsmaru/incus/migration.ex',['test/migration_target_test.exs','test/copy_negotiation_reference_test.exs'])
models.add('ServerEnvironment')
helpers['SendEvent']=('lib/opsmaru/incus/events.ex',['test/event_send_test.exs'])
models.add('Event')
for name in ['GetStorageVolumeFile','CreateStorageVolumeFile','DeleteStorageVolumeFile','GetInstanceBackupFile','GetStorageVolumeBackupFile','GetStoragePoolBucketBackupFile','CreateInstanceBackupStream','CreateStorageVolumeBackupStream','CreateStoragePoolBucketBackupStream','CreateStoragePoolVolumeFromBackup','CreateStoragePoolVolumeFromISO','CreateStoragePoolBucketFromBackup']:
 helpers[name]=('lib/opsmaru/incus/files.ex',['test/file_variants_reference_test.exs','test/backup_variants_test.exs'])
for name in ['StatusCode.String','StatusCode.IsFinal','StatusCodeFromString']:
 helpers[name]=('lib/opsmaru/incus/status.ex',['test/model_helpers_reference_test.exs'])
for name in ['GetStoragePoolVolumeFileSFTPConn','GetStoragePoolVolumeBlockNBDConn']:
 helpers[name]=('lib/opsmaru/incus.ex',['test/volume_upgrade_reference_test.exs'])
helpers['GetPrivateImageFile']=('lib/opsmaru/incus/images.ex',['test/private_image_reference_test.exs'])
helpers['ConsoleInstanceDynamic']=('lib/opsmaru/incus/dynamic_console.ex',['test/dynamic_console_reference_test.exs'])
for name in ['ConfigMap.UnmarshalJSON','DevicesMap.UnmarshalJSON']:
 helpers[name]=('lib/opsmaru/incus/native_config.ex',['test/native_config_reference_test.exs'])
for name in ['Operation.AddHandler','Operation.RemoveHandler','operation.AddHandler','operation.RemoveHandler']:
 helpers[name]=('lib/opsmaru/incus/operation.ex',['test/operation_handler_test.exs'])
for name in ['RemoteOperation.AddHandler','remoteOperation.AddHandler']:
 helpers[name]=('lib/opsmaru/incus/migration.ex',['test/operation_handler_test.exs'])
for name in ['RemoteOperation.Wait','remoteOperation.Wait']:
 helpers[name]=('lib/opsmaru/incus/migration.ex',['test/copy_negotiation_reference_test.exs','test/migration_target_test.exs'])
client_interface_types = {'Operation': ('lib/opsmaru/incus/operation.ex',['test/operation_test.exs','test/operation_handler_test.exs']), 'RemoteOperation': ('lib/opsmaru/incus/migration.ex',['test/migration_target_test.exs','test/operation_handler_test.exs','test/copy_negotiation_reference_test.exs'])}
helpers['ServerFiltered.MarshalYAML']=('lib/opsmaru/incus/server_yaml.ex',['test/server_yaml_reference_test.exs'])
for name in ['ConfigMap.UnmarshalYAML','DevicesMap.UnmarshalYAML']:
 helpers[name]=('lib/opsmaru/incus/native_yaml.ex',['test/native_yaml_reference_test.exs'])
helpers['ApplyServerPreseed']=('lib/opsmaru/incus/preseed.ex',['test/preseed_reference_test.exs'])
preseed_types = 'InitPreseed InitLocalPreseed InitClusterPreseed InitNetworksProjectPost InitStorageVolumesProjectPost InitProfileProjectPost'.split()
models.update(preseed_types)
network_normalisers = 'NetworkACLRule NetworkAddressSet NetworkForwardPort NetworkForwardPut NetworkForwardsPost NetworkLoadBalancerBackend NetworkLoadBalancerPort NetworkLoadBalancerPut'.split()
for name in network_normalisers:
 helpers[name+'.Normalise']=('lib/opsmaru/incus/network_models.ex',['test/network_models_reference_test.exs'])
models.update(network_normalisers)
for name in ['GetHTTPClient','DoHTTP']:
 helpers[name]=('lib/opsmaru/incus/http.ex',['test/http_reference_test.exs'])
helpers['DoWebsocket']=('lib/opsmaru/incus/web_socket.ex',['test/direct_websocket_reference_test.exs','test/web_socket_test.exs','test/tls_stream_test.exs'])
for name in ['CertificateAddToken.String','ClusterMemberJoinToken.String','Operation.ToCertificateAddToken','Operation.ToClusterJoinToken']:
 helpers[name]=('lib/opsmaru/incus/tokens.ex',['test/metadata_helpers_reference_test.exs'])
for name in ['Response.MetadataAsMap','Response.MetadataAsOperation','Response.MetadataAsStringSlice','Response.MetadataAsStruct']:
 helpers[name]=('lib/opsmaru/incus/response.ex',['test/metadata_helpers_reference_test.exs'])
for name in ['EventListener.AddHandler','EventListener.RemoveHandler','EventListener.Wait','EventListener.IsActive','EventListener.Disconnect']:
 helpers[name]=('lib/opsmaru/incus/event_listener.ex',['test/event_listener_test.exs'])
oci_helpers = 'Disconnect GetImageAliasArchitectures GetImage GetImageAlias GetImageAliasType GetImageFile GetImages GetImagesAllProjects GetImagesAllProjectsWithFilter GetImagesWithFilter GetImageFingerprints GetImageAliases GetImageAliasNames GetImageSecret GetPrivateImage GetPrivateImageFile ExportImage'.split()
for name in oci_helpers:
 helpers['ProtocolOCI.'+name]=('lib/opsmaru/incus/oci.ex',['test/oci_test.exs'])
for name in ['GetConnectionInfo','GetHTTPClient','DoHTTP']:
 helpers['ProtocolOCI.'+name]=('lib/opsmaru/incus/oci.ex',['test/oci_origin_reference_test.exs'])
helpers['ConnectOCI']=('lib/opsmaru/incus/oci.ex',['test/oci_test.exs'])
simple_helpers = 'GetConnectionInfo Disconnect GetHTTPClient DoHTTP GetImages GetImagesAllProjects GetImagesAllProjectsWithFilter GetImagesWithFilter GetImageFingerprints GetImage GetImageFile GetImageSecret GetPrivateImage GetPrivateImageFile GetImageAliases GetImageAliasNames GetImageAlias GetImageAliasType GetImageAliasArchitectures ExportImage'.split()
for name in simple_helpers:
 helpers['ProtocolSimpleStreams.'+name]=('lib/opsmaru/incus/simple_streams.ex',['test/simple_streams_test.exs'])
helpers['ConnectSimpleStreams']=('lib/opsmaru/incus/simple_streams.ex',['test/simple_streams_test.exs'])
helpers['ParseFileHeaders']=('lib/opsmaru/incus/file_headers.ex',['test/file_headers_reference_test.exs'])
for name in ['Server.Filtered','Event.ToLogging']:
 helpers[name]=('lib/opsmaru/incus/projections.ex',['test/projections_reference_test.exs'])
projection_types = 'ServerFiltered EventLogRecord EventLogging EventLifecycle EventLifecycleRequestor'.split()
models.update(projection_types)
helpers['MetadataConfiguration.GetKeys']=('lib/opsmaru/incus/metadata.ex',['test/metadata_keys_reference_test.exs'])
metadata_types = 'MetadataConfiguration MetadataConfig MetadataConfigEntityName MetadataConfigGroupName MetadataConfigGroup MetadataConfigKey'.split()
models.update(metadata_types)
nested_model_types = 'AccessEntry BackupTarget CertificateAddToken ClusterMemberConfigKey ClusterMemberJoinToken ClusterMemberSysInfo ImageAlias ImageMetadataTemplate ImageSource ImagesPostSource InstanceConsoleControl InstanceDebugRepairPost InstanceExecControl InstancePostTarget InstanceSource InstanceStateCPU InstanceStateDisk InstanceStateMemory InstanceStateNetwork InstanceStateNetworkAddress InstanceStateNetworkCounters InstanceStateOSInfo InstanceType NetworkLoadBalancerStateBackendHealth NetworkLoadBalancerStateBackendHealthPort NetworkStateAddress NetworkStateBond NetworkStateBridge NetworkStateCounters NetworkStateOVN NetworkStateVLAN NetworkZoneRecordEntry ProjectStateResource ResourcesCPU ResourcesCPUAddressSizes ResourcesCPUCache ResourcesCPUCore ResourcesCPUSocket ResourcesCPUThread ResourcesGPU ResourcesGPUCard ResourcesGPUCardDRM ResourcesGPUCardMdev ResourcesGPUCardNvidia ResourcesGPUCardSRIOV ResourcesLoad ResourcesMemory ResourcesMemoryNode ResourcesNetwork ResourcesNetworkCard ResourcesNetworkCardPort ResourcesNetworkCardPortInfiniband ResourcesNetworkCardSRIOV ResourcesNetworkCardVDPA ResourcesPCI ResourcesPCIDevice ResourcesPCIVPD ResourcesSerial ResourcesSerialDevice ResourcesStorage ResourcesStorageDisk ResourcesStorageDiskPartition ResourcesStoragePoolInodes ResourcesStoragePoolSpace ResourcesSystem ResourcesSystemChassis ResourcesSystemFirmware ResourcesSystemMotherboard ResourcesUSB ResourcesUSBDevice ResourcesUSBDeviceInterface ServerStorageDriverInfo ServerUntrusted StorageBucketBackup StorageBucketBackupPost StoragePoolState StorageVolumePostTarget StorageVolumeSource StorageVolumeStateUsage'.split()
models.update(nested_model_types)
for name in ['StatusErrorf','StatusErrorMatch','StatusErrorCheck','StatusError.Error','StatusError.Status']:
 helpers[name]=('lib/opsmaru/incus/status_error.ex',['test/status_error_reference_test.exs'])
entries=[]
for entry in inv['entries']:
 name=entry['name'].split('.')[-1]
 row=dict(id=entry['id'], status='missing', elixir=None, evidence=[], note='No verified implementation/evidence claim.')
 if entry['name'] in helpers and entry['name'].startswith(('ProtocolOCI.', 'ConnectOCI')):
  impl,evidence=helpers[entry['name']];row.update(status='partial',elixir=impl,evidence=evidence,note='Explicit host-adapter OCI slice: pinned alias/image/unsupported helper differential; independent binary/budget/cleanup fixtures. Installed host conversion, TLS and full OCI parity remain unverified.')
 elif entry['name'] in helpers and entry['name'].startswith(('ProtocolSimpleStreams.', 'ConnectSimpleStreams')):
  impl,evidence=helpers[entry['name']];row.update(status='partial',elixir=impl,evidence=evidence,note='Explicit verified-HTTPS SimpleStreams slice: pinned catalog/image/alias/file-manifest/unsupported differential; independent checksummed binary/deadline/owner fixtures. No socket discovery, HTTP downgrade or disk cache. Explicit host delta callback, checksum, budget and cleanup fixtures pass; installed conversion and full protocol parity remain unverified. Passive CA-configured origin metadata has pinned differential and no-I/O evidence. Origin HTTP/disconnect have pinned differential and independent bounds/no-redirect evidence.')
 elif entry['kind'] == 'method' and entry['name'].startswith(('ProtocolOCI.', 'ProtocolSimpleStreams.')):
  pass # Native Incus methods do not establish OCI or SimpleStreams implementation parity.
 elif entry['package']=='shared/api' and entry['kind']=='type' and name == 'URL':
  row.update(status='partial',elixir='lib/opsmaru/incus/url.ex',evidence=['test/url_reference_test.exs'],note='Pure immutable bounded native URL builder; all exported builder helpers compared with unchanged reference. Not a connection, origin authorization or full embedded net/url API port.')
 elif entry['package']=='shared/api' and entry['kind']=='type' and name == 'StatusError':
  row.update(status='partial',elixir='lib/opsmaru/incus/status_error.ex',evidence=['test/status_error_reference_test.exs'],note='Pure bounded native status/message value; zero value, status text and match helpers compared with unchanged reference. No Go fmt formatting or errors.As unwrapping.')
 elif entry['package']=='shared/api' and entry['kind']=='type' and name in ['Response','ResponseRaw','ResponseType']:
  row.update(status='partial',elixir='lib/opsmaru/incus/response.ex',evidence=['test/response_models_reference_test.exs'],note='Bounded explicit native JSON projection plus lossless model schemas: defaults/nulls, open string enum, int64 rejection and RawMessage versus float64 any metadata compared with unchanged native types. Parsed RawMessage JSON and exact ResponseRaw float64 bits compared; no raw JSON spelling/whitespace preservation. Duplicate-key merging, ambiguous case aliases, non-ASCII envelope keys, ResponseRaw integer-mantissa negative zero and inputs outside byte/depth limits reject. YAML and full type parity remain unverified.')
 elif entry['package']=='shared/api' and entry['kind']=='type' and name in ['ConfigMap','DevicesMap']:
  row.update(status='partial',elixir='lib/opsmaru/incus/native_config.ex',evidence=['test/native_config_reference_test.exs','test/native_yaml_reference_test.exs'],note='Explicit bounded native JSON coercion and a strict-subset YAML decoder that equals native go-yaml v4 or rejects; YAML outside the subset and full type parity remain open.')
 elif entry['package']=='client' and entry['kind']=='type' and entry['name'] in client_interface_types:
  impl,evidence=client_interface_types[entry['name']];row.update(status='partial',elixir=impl,evidence=evidence,note='Immutable handle counterpart of the native interface; every interface method has bounded partial evidence. Native mutable listener lifetime and asynchronous handler attachment are not reproduced.')
 elif entry['package']=='client' and entry['kind'] in ['method','interface_method'] and name in sftp_helpers:
  row.update(status='partial',elixir='lib/opsmaru/incus/sftp.ex',evidence=['test/sftp_helpers_reference_test.exs'],note='User-approved bounded SFTP v3 subset: unchanged Incus helper initialization, extensions, five open modes, positional binary read/write and file/session close compared over Unix and verified HTTPS; independent malformed/oversize/deadline/cancellation/owner/EOF cleanup fixtures. One owner/request, bounded packets/handles; short DATA and other protocol operations reject. Native status code/message/language retained rather than Go filesystem-error normalization. Full pkg/sftp.Client parity and new installed/backend/hardware acceptance are not claimed.')
 elif entry['package']=='client' and entry['kind'] in ['method','interface_method'] and name == 'ExecInstance':
  row.update(status='partial',elixir='lib/opsmaru/incus/session.ex',evidence=['test/resource_slice_test.exs','test/session_test.exs','test/exec_output_test.exs'],note='The POST /1.0/instances/{name}/exec endpoint row and S01 are complete under reviewed record b03_exec_v1: collected noninteractive Session.run, non-waiting Incus.call, interactive PTY Session.exec with resize/signal control frames, record-output submission and nonzero user/group/cwd/terminal size compared with unchanged ExecInstance over Unix and verified mutual HTTPS, including container_exec_recording/container_exec_user_group_cwd rejection before dispatch, native 400/403/404, upgrade targets and empty output. Independent fixtures on both transports cover preflight, stdin chunking and blocked stdin, deadline/cancellation, owner loss, sink limits, running/failed completion, close/barrier/abrupt outcomes, negotiation and fds metadata failures, request-context deadline/cancellation during upgrade, pending status, missing channels and redaction with peer closure. Interactive sessions expose host-owned channels instead of reader/writer mirroring, and upgrades keep host project/target routing (approved difference); recorded-output retrieval stays in B07. Endpoint completion is not Go declaration parity.')
 elif entry['package']=='client' and entry['kind'] in ['method','interface_method'] and name in ['GetOperationWait','GetOperationWaitSecret']:
  row.update(status='partial',elixir='lib/opsmaru/incus/api.ex',evidence=['test/resource_slice_test.exs','test/native_wait_reference_test.exs'],note='Direct typed native wait, separate from polling Operation.wait. The GET /1.0/operations/{id}/wait endpoint row is complete under reviewed record b03_native_wait_v1: finite queries, scoped routing/ETags, gated bodies after flushed headers, running/completed/failed/cancelled snapshots, HTTP 403/404, premature EOF and pre-header loss compared with the unchanged pinned client over Unix and verified mutual HTTPS. Independent local deadline/cancellation/caller-loss peer cleanup, no replay/DELETE, preflight rejection of timeout outside 0..3600 and of empty/non-hex secrets, and Inspect redaction. Approved exclusions: public view, arbitrary/empty secrets and cluster forwarding; native timeout=-1 is intentionally rejected. Endpoint completion is not Go declaration parity; real-daemon acceptance is separate.')
 elif entry['package']=='client' and entry['kind'] in ['method','interface_method'] and name in ['GetInstances', 'GetInstance', 'GetInstanceState', 'GetInstanceSnapshots', 'GetInstanceSnapshot', 'GetImages', 'GetImage', 'GetOperations', 'GetOperation']:
  row.update(status='partial',elixir='lib/opsmaru/incus/api.ex',evidence=['test/resource_slice_test.exs','test/inspection_contract_test.exs'],note='Core inspection v1: catalogue queries, container instance samples and fixed populated/empty DTO fields, grouped operations without cross-group ordering, corruption and native 403/404 compared with unchanged named Go methods on Unix/mutual HTTPS. Applicable ETags, routing/binding, independent unknown fields, byte/readiness bounds and deadline/cancellation peer cleanup. Additional selectors/types/fields/errors, tool policy, backend acceptance and whole endpoint/declaration parity remain unverified.')
 elif entry['package']=='client' and entry['kind'] in ['method','interface_method'] and name in ['GetProjects', 'GetProject', 'GetProfiles', 'GetProfile', 'GetNetworks', 'GetNetwork', 'GetStoragePools', 'GetStoragePool', 'GetStoragePoolVolumes', 'GetStoragePoolVolume']:
  row.update(status='partial',elixir='lib/opsmaru/incus/api.ex',evidence=['test/resource_slice_test.exs','test/inspection_contract_test.exs'],note='Initial-tool inspection v1: named catalogue method/query with typed populated/empty results, 403/404, metadata type rejection and routing/binding on Unix and verified mutual HTTPS; native getter ETags and independent list-header retention, response bounds, declared-extension preflight and deadline/cancellation peer cleanup. Custom volume samples only; unknown field retention is independent of native DTO projection. Other query/type/field/error variants, tool policy and backend acceptance remain unverified; whole endpoint and declaration remain partial.')
 elif entry['package']=='client' and entry['kind'] in ['method','interface_method'] and name in ['CreateInstance','UpdateInstance','UpdateInstanceState','DeleteInstance','CreateInstanceSnapshot','DeleteInstanceSnapshot','DeleteImage','DeleteOperation']:
  row.update(status='partial',elixir='lib/opsmaru/incus/api.ex',evidence=['test/resource_slice_test.exs','test/mutation_lifecycle_test.exs','test/native_wait_reference_test.exs'],note='Initial mutation lifecycle v1: bounded named-Go request/acceptance and direct native /wait running/success/failure composition over Unix/mutual HTTPS, including instance update/restore, applicable PUT ETags, native rejection, malformed/lost replies, retained identity and no replay. DeleteOperation is synchronous acknowledgement; public cancellation permission/race/lost-reply behavior has independent fixtures, not full Go Cancel parity. Broader bodies, source/state/extension/error/cluster variants and real-backend acceptance remain unverified; whole endpoints and declarations stay partial.')
  if name != 'CreateInstance': row['note'] += ' The endpoint row is complete under a reviewed b01 completion record covering every body field/action, extension guards before dispatch and the cancelled snapshot on both transports; cluster forwarding is excluded. Endpoint completion is not Go declaration parity.'
 elif entry['kind'] in ['method','interface_method'] and name in methods:
  row.update(status='partial',elixir='lib/opsmaru/incus/api.ex',evidence=['test/resource_slice_test.exs'] + (['test/session_test.exs'] if name in ['ExecInstance','ConsoleInstance'] else []) + (['test/migration_test.exs'] if name.startswith('Migrate') else []),note='Pinned official method request/result differential, unavailable-extension and native-error slice. Convenience orchestration and full parity remain separate.')
 elif entry['kind'] in ['method','interface_method','function'] and (entry['name'] in helpers or name in helpers):
  impl,evidence=helpers.get(entry['name'],helpers.get(name));row.update(status='partial',elixir=impl,evidence=evidence,note='Bounded helper slice only; consult public coverage limitations before use.')
 elif entry['package']=='client' and entry['kind'] in ['method','interface_method'] and name in event_subscriptions:
  row.update(status='partial',elixir='lib/opsmaru/incus/events.ex',evidence=['test/event_contract_test.exs','test/event_listener_test.exs','test/web_socket_test.exs','test/tls_stream_test.exs'],note='Explicit owner-bound subscription. The GET /1.0/events endpoint row and S03 are complete under reviewed record b03_events_v1: type/all-projects selectors, host project/target routing, native 400/403/404 upgrade rejection and Event fields compared with the unchanged pinned client over Unix and verified mutual HTTPS, with independent listener, send, bound, lifetime and peer-closure evidence. The pinned shared per-project connection and asynchronous mutable listener are not reproduced; cluster forwarding and callback ordering are excluded. Endpoint completion is not Go declaration parity.')
 elif entry['package']=='shared/api' and entry['kind']=='type' and name in models:
  evidence = ['test/resource_slice_test.exs'] if name in {m[key] for m in methods.values() for key in ['body','model'] if m[key]} else []
  if name in writable_types or name.removesuffix('Put') in writable_types or name == 'StatusCode': evidence.append('test/model_helpers_reference_test.exs')
  if name in ['InstancePut','ProjectPut','ProfilePut','ImagePut','InstanceSnapshotPut']: evidence.append('test/instance_patch_test.exs')
  if name == 'ServerEnvironment': evidence.append('test/discovery_helpers_test.exs')
  if name == 'Event': evidence += ['test/event_send_test.exs','test/event_contract_test.exs']
  if name in ['InstanceExecPost','InstanceExecControl']: evidence.append('test/exec_output_test.exs')
  if name in preseed_types: evidence.append('test/preseed_reference_test.exs')
  if name in network_normalisers: evidence.append('test/network_models_reference_test.exs')
  if name in projection_types: evidence.append('test/projections_reference_test.exs')
  if name in metadata_types: evidence.append('test/metadata_keys_reference_test.exs')
  if name in nested_model_types: evidence.append('test/nested_models_reference_test.exs')
  row.update(status='partial',elixir='lib/opsmaru/incus/model.ex',evidence=evidence,note='Native schema/differential model slice; optional/null and populated writable projections where cited. Remaining type-helper parity unverified.')
 elif entry['package']=='shared/api' and entry['kind'] in ['const','var'] and entry['source']=='shared/api/status_code.go':
  row.update(status='partial',elixir='lib/opsmaru/incus/status.ex',evidence=['test/model_helpers_reference_test.exs'],note='All pinned status names/values and unknown-code behavior compared with unchanged native helpers.')
 elif entry['package']=='shared/api' and entry['kind']=='const' and entry['name'] in constants:
  row.update(status='partial',elixir='lib/opsmaru/incus/constants.ex',evidence=['test/constants_reference_test.exs'],note='Pinned native API constant values compared through unchanged exports. Pure model data only; no protocol activation or capability grant implied.')
 if entry['package']=='client' and entry['kind'] in ['method','interface_method'] and name == 'GetOperationWait':
  row['evidence'].append('test/mutation_lifecycle_test.exs')
 if name == 'GetServer' and row['evidence'] and entry['package']=='client':
  row['note'] += ' connect/2 discovery has RawQuery transport differential plus independent required-field/version/readiness/bounds/lifetime evidence on Unix/mutual HTTPS; not named Go GetServer DTO parity.'
 entries.append(row)
for row in entries:
 for path in row['evidence']: assert (root/path).is_file(), path
(root/'priv/incus/coverage.json').write_text(json.dumps(dict(reference_revision=inv['reference']['revision'],complete_port=False,endpoint_evidence='priv/incus/endpoint-evidence.json',endpoint_inventory='priv/incus/endpoint-inventory.json',entries=entries),indent=2)+'\n')
print(f"{len(methods)} JSON method descriptors (named Go methods plus explicit REST slices); {sum(x['status']=='partial' for x in entries)} partial declaration mappings; {sum(x['status']=='missing' for x in entries)} missing declarations; complete_port=false")
