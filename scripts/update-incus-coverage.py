"""Regenerate evidence mappings; never upgrade a fixture slice to full parity."""
import json
from pathlib import Path
root = Path(__file__).resolve().parents[1]
def load(path): return json.loads((root/path).read_text())
inv = load('priv/incus/inventory.json')
methods = {m['name']: m for m in load('priv/incus/methods.json')['methods']}
models = {m[key] for m in methods.values() for key in ['body','model'] if m[key]}
helpers = {
 'RawQuery': ('lib/opsmaru/incus.ex', ['test/library/client_test.exs','test/library/reference_wire_test.exs']),
 'UseProject': ('lib/opsmaru/incus.ex',['test/library/resource_slice_test.exs']),
 'UseTarget': ('lib/opsmaru/incus.ex',['test/library/resource_slice_test.exs']),
 'HasExtension': ('lib/opsmaru/incus.ex',['test/library/client_test.exs']),
 'CheckExtension': ('lib/opsmaru/incus.ex',['test/library/client_test.exs']),
 'GetServer': ('lib/opsmaru/incus.ex',['test/library/client_test.exs']),
}
for name in ['GetImageFile','GetImageAliasType','GetImageAliasArchitectures','GetImageSecret','CopyImage']:
 helpers[name]=('lib/opsmaru/incus/images.ex',['test/library/image_transfer_test.exs'])
for name in ['GetInstanceFile','CreateInstanceFile','CreateInstanceFromBackup']:
 helpers[name]=('lib/opsmaru/incus/files.ex',['test/library/file_reference_test.exs'])
for name in ['GetInstanceFileSFTPConn','GetInstanceNBDConn']:
 helpers[name]=('lib/opsmaru/incus/raw_channel.ex',['test/library/raw_channel_test.exs','test/library/native_upgrade_reference_test.exs','test/library/tls_stream_test.exs'])
for name in ['GetEvents','GetEventsByType','GetEventsAllProjects','GetEventsAllProjectsByType','RawWebsocket','GetOperationWebsocket']:
 helpers[name]=('lib/opsmaru/incus/web_socket.ex',['test/library/web_socket_test.exs','test/library/tls_stream_test.exs'])
for name in ['operation.Wait','operation.Cancel','operation.Get']:
 helpers[name]=('lib/opsmaru/incus/operation.ex',['test/library/operation_test.exs'])
for name in ['CopyInstance','CopyInstanceSnapshot','CopyStoragePoolVolume']:
 helpers[name]=('lib/opsmaru/incus/copy.ex',['test/library/copy_test.exs','test/library/migration_test.exs'])
helpers['CopyInstance'][1].append('test/library/copy_guards_test.exs')
for name in ['GetMetrics','GetNetworkACLLogfile','GetInstanceLogfile','GetInstanceConsoleLog','GetInstanceTemplateFile','CreateInstanceTemplateFile','GetInstanceDebugMemory']:
 helpers[name]=('lib/opsmaru/incus/streams.ex',['test/library/streams_test.exs'])
for name in ['CopyInstance','CopyInstanceSnapshot','CopyStoragePoolVolume','MoveStoragePoolVolume']:
 helpers.setdefault(name, ('lib/opsmaru/incus/copy.ex', []))[1].append('test/library/copy_negotiation_reference_test.exs')
for name in ['CreateInstanceFromImage','RebuildInstanceFromImage']:
 helpers[name]=('lib/opsmaru/incus/image_instances.ex',['test/library/copy_negotiation_reference_test.exs'])
helpers['RawOperation']=('lib/opsmaru/incus/operation.ex',['test/library/raw_operation_reference_test.exs'])
writable_types = 'Certificate ClusterMember ClusterGroup Image Instance InstanceSnapshot Network NetworkACL NetworkAddressSet NetworkForward NetworkIntegration NetworkLoadBalancer NetworkPeer NetworkZone NetworkZoneRecord Profile Project Server StoragePool StorageBucket StorageBucketKey StorageVolume StorageVolumeSnapshot'.split()
for name in writable_types:
 helpers[name+'.Writable']=('lib/opsmaru/incus/model.ex',['test/library/model_helpers_reference_test.exs'])
models.update(writable_types)
models.update(name+'Put' for name in writable_types)
models.add('StatusCode')
helpers['Instance.IsActive']=('lib/opsmaru/incus/model.ex',['test/library/model_helpers_reference_test.exs'])
for name in ['NetworkForward','NetworkLoadBalancer','NetworkPeer','StorageBucket','StorageBucketKey']:
 helpers[name+'.Etag']=('lib/opsmaru/incus/model.ex',['test/library/model_helpers_reference_test.exs'])
for name in ['Certificate','Image','Instance','NetworkACL','Profile','Project','StorageBucket','StorageBucketKey','StorageVolume']:
 helpers[name+'.URL']=('lib/opsmaru/incus/model_url.ex',['test/library/model_helpers_reference_test.exs'])
helpers['GetParentAndSnapshotName']=('lib/opsmaru/incus/model_url.ex',['test/library/model_helpers_reference_test.exs'])
for name in ['GetConnectionInfo','IsClustered','IsAgent','RequireAuthenticated']:
 helpers[name]=('lib/opsmaru/incus/discovery.ex',['test/library/discovery_helpers_test.exs','test/library/authenticated_header_test.exs'])
for name in ['GetTarget','CancelTarget']:
 helpers[name]=('lib/opsmaru/incus/migration.ex',['test/library/migration_target_test.exs','test/library/copy_negotiation_reference_test.exs'])
models.add('ServerEnvironment')
helpers['SendEvent']=('lib/opsmaru/incus/events.ex',['test/library/event_send_test.exs'])
models.add('Event')
for name in ['GetStorageVolumeFile','CreateStorageVolumeFile','DeleteStorageVolumeFile','GetInstanceBackupFile','GetStorageVolumeBackupFile','GetStoragePoolBucketBackupFile','CreateInstanceBackupStream','CreateStorageVolumeBackupStream','CreateStoragePoolBucketBackupStream','CreateStoragePoolVolumeFromBackup','CreateStoragePoolVolumeFromISO','CreateStoragePoolBucketFromBackup']:
 helpers[name]=('lib/opsmaru/incus/files.ex',['test/library/file_variants_reference_test.exs','test/library/backup_variants_test.exs'])
for name in ['StatusCode.String','StatusCode.IsFinal','StatusCodeFromString']:
 helpers[name]=('lib/opsmaru/incus/status.ex',['test/library/model_helpers_reference_test.exs'])
entries=[]
for entry in inv['entries']:
 name=entry['name'].split('.')[-1]
 row=dict(id=entry['id'], status='missing', elixir=None, evidence=[], note='No verified implementation/evidence claim.')
 if entry['kind'] in ['method','interface_method'] and name in methods:
  row.update(status='partial',elixir='lib/opsmaru/incus/api.ex',evidence=['test/library/resource_slice_test.exs'] + (['test/library/session_test.exs'] if name in ['ExecInstance','ConsoleInstance'] else []) + (['test/library/migration_test.exs'] if name.startswith('Migrate') else []),note='Pinned official method request/result differential, unavailable-extension and native-error slice. Convenience orchestration and full parity remain separate.')
 elif entry['kind'] in ['method','interface_method','function'] and (entry['name'] in helpers or name in helpers):
  impl,evidence=helpers.get(entry['name'],helpers.get(name));row.update(status='partial',elixir=impl,evidence=evidence,note='Bounded helper slice only; consult public coverage limitations before use.')
 elif entry['package']=='shared/api' and entry['kind']=='type' and name in models:
  evidence = ['test/library/resource_slice_test.exs'] if name in {m[key] for m in methods.values() for key in ['body','model'] if m[key]} else []
  if name in writable_types or name.removesuffix('Put') in writable_types or name == 'StatusCode': evidence.append('test/library/model_helpers_reference_test.exs')
  if name == 'ServerEnvironment': evidence.append('test/library/discovery_helpers_test.exs')
  if name == 'Event': evidence.append('test/library/event_send_test.exs')
  row.update(status='partial',elixir='lib/opsmaru/incus/model.ex',evidence=evidence,note='Native schema/differential model slice; optional/null and populated writable projections where cited. Remaining type-helper parity unverified.')
 elif entry['package']=='shared/api' and entry['kind'] in ['const','var'] and entry['source']=='shared/api/status_code.go':
  row.update(status='partial',elixir='lib/opsmaru/incus/status.ex',evidence=['test/library/model_helpers_reference_test.exs'],note='All pinned status names/values and unknown-code behavior compared with unchanged native helpers.')
 entries.append(row)
for row in entries:
 for path in row['evidence']: assert (root/path).is_file(), path
(root/'priv/incus/coverage.json').write_text(json.dumps(dict(reference_revision=inv['reference']['revision'],complete_port=False,entries=entries),indent=2)+'\n')
print(f"{len(methods)} differential JSON methods; {sum(x['status']=='partial' for x in entries)} partial declaration mappings; {sum(x['status']=='missing' for x in entries)} missing declarations; complete_port=false")
