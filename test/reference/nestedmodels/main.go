// Fixture-only unchanged shared/api nested model oracle; no backend, network or files.
package main

import (
	"encoding/json"
	"fmt"
	"os"

	"github.com/lxc/incus/v7/shared/api"
)

func ptr[T any]() any {
	var v T
	return &v
}

var registry = map[string]func() any{
	"AccessEntry":                                ptr[api.AccessEntry],
	"BackupTarget":                               ptr[api.BackupTarget],
	"CertificateAddToken":                        ptr[api.CertificateAddToken],
	"ClusterMemberConfigKey":                     ptr[api.ClusterMemberConfigKey],
	"ClusterMemberJoinToken":                     ptr[api.ClusterMemberJoinToken],
	"ClusterMemberSysInfo":                       ptr[api.ClusterMemberSysInfo],
	"ImageAlias":                                 ptr[api.ImageAlias],
	"ImageMetadataTemplate":                      ptr[api.ImageMetadataTemplate],
	"ImageSource":                                ptr[api.ImageSource],
	"ImagesPostSource":                           ptr[api.ImagesPostSource],
	"InstanceConsoleControl":                     ptr[api.InstanceConsoleControl],
	"InstanceDebugRepairPost":                    ptr[api.InstanceDebugRepairPost],
	"InstanceExecControl":                        ptr[api.InstanceExecControl],
	"InstancePostTarget":                         ptr[api.InstancePostTarget],
	"InstanceSource":                             ptr[api.InstanceSource],
	"InstanceStateCPU":                           ptr[api.InstanceStateCPU],
	"InstanceStateDisk":                          ptr[api.InstanceStateDisk],
	"InstanceStateMemory":                        ptr[api.InstanceStateMemory],
	"InstanceStateNetwork":                       ptr[api.InstanceStateNetwork],
	"InstanceStateNetworkAddress":                ptr[api.InstanceStateNetworkAddress],
	"InstanceStateNetworkCounters":               ptr[api.InstanceStateNetworkCounters],
	"InstanceStateOSInfo":                        ptr[api.InstanceStateOSInfo],
	"InstanceType":                               ptr[api.InstanceType],
	"NetworkLoadBalancerStateBackendHealth":      ptr[api.NetworkLoadBalancerStateBackendHealth],
	"NetworkLoadBalancerStateBackendHealthPort":  ptr[api.NetworkLoadBalancerStateBackendHealthPort],
	"NetworkStateAddress":                        ptr[api.NetworkStateAddress],
	"NetworkStateBond":                           ptr[api.NetworkStateBond],
	"NetworkStateBridge":                         ptr[api.NetworkStateBridge],
	"NetworkStateCounters":                       ptr[api.NetworkStateCounters],
	"NetworkStateOVN":                            ptr[api.NetworkStateOVN],
	"NetworkStateVLAN":                           ptr[api.NetworkStateVLAN],
	"NetworkZoneRecordEntry":                     ptr[api.NetworkZoneRecordEntry],
	"ProjectStateResource":                       ptr[api.ProjectStateResource],
	"ResourcesCPU":                               ptr[api.ResourcesCPU],
	"ResourcesCPUAddressSizes":                   ptr[api.ResourcesCPUAddressSizes],
	"ResourcesCPUCache":                          ptr[api.ResourcesCPUCache],
	"ResourcesCPUCore":                           ptr[api.ResourcesCPUCore],
	"ResourcesCPUSocket":                         ptr[api.ResourcesCPUSocket],
	"ResourcesCPUThread":                         ptr[api.ResourcesCPUThread],
	"ResourcesGPU":                               ptr[api.ResourcesGPU],
	"ResourcesGPUCard":                           ptr[api.ResourcesGPUCard],
	"ResourcesGPUCardDRM":                        ptr[api.ResourcesGPUCardDRM],
	"ResourcesGPUCardMdev":                       ptr[api.ResourcesGPUCardMdev],
	"ResourcesGPUCardNvidia":                     ptr[api.ResourcesGPUCardNvidia],
	"ResourcesGPUCardSRIOV":                      ptr[api.ResourcesGPUCardSRIOV],
	"ResourcesLoad":                              ptr[api.ResourcesLoad],
	"ResourcesMemory":                            ptr[api.ResourcesMemory],
	"ResourcesMemoryNode":                        ptr[api.ResourcesMemoryNode],
	"ResourcesNetwork":                           ptr[api.ResourcesNetwork],
	"ResourcesNetworkCard":                       ptr[api.ResourcesNetworkCard],
	"ResourcesNetworkCardPort":                   ptr[api.ResourcesNetworkCardPort],
	"ResourcesNetworkCardPortInfiniband":         ptr[api.ResourcesNetworkCardPortInfiniband],
	"ResourcesNetworkCardSRIOV":                  ptr[api.ResourcesNetworkCardSRIOV],
	"ResourcesNetworkCardVDPA":                   ptr[api.ResourcesNetworkCardVDPA],
	"ResourcesPCI":                               ptr[api.ResourcesPCI],
	"ResourcesPCIDevice":                         ptr[api.ResourcesPCIDevice],
	"ResourcesPCIVPD":                            ptr[api.ResourcesPCIVPD],
	"ResourcesSerial":                            ptr[api.ResourcesSerial],
	"ResourcesSerialDevice":                      ptr[api.ResourcesSerialDevice],
	"ResourcesStorage":                           ptr[api.ResourcesStorage],
	"ResourcesStorageDisk":                       ptr[api.ResourcesStorageDisk],
	"ResourcesStorageDiskPartition":              ptr[api.ResourcesStorageDiskPartition],
	"ResourcesStoragePoolInodes":                 ptr[api.ResourcesStoragePoolInodes],
	"ResourcesStoragePoolSpace":                  ptr[api.ResourcesStoragePoolSpace],
	"ResourcesSystem":                            ptr[api.ResourcesSystem],
	"ResourcesSystemChassis":                     ptr[api.ResourcesSystemChassis],
	"ResourcesSystemFirmware":                    ptr[api.ResourcesSystemFirmware],
	"ResourcesSystemMotherboard":                 ptr[api.ResourcesSystemMotherboard],
	"ResourcesUSB":                               ptr[api.ResourcesUSB],
	"ResourcesUSBDevice":                         ptr[api.ResourcesUSBDevice],
	"ResourcesUSBDeviceInterface":                ptr[api.ResourcesUSBDeviceInterface],
	"ServerStorageDriverInfo":                    ptr[api.ServerStorageDriverInfo],
	"ServerUntrusted":                            ptr[api.ServerUntrusted],
	"StorageBucketBackup":                        ptr[api.StorageBucketBackup],
	"StorageBucketBackupPost":                    ptr[api.StorageBucketBackupPost],
	"StoragePoolState":                           ptr[api.StoragePoolState],
	"StorageVolumePostTarget":                    ptr[api.StorageVolumePostTarget],
	"StorageVolumeSource":                        ptr[api.StorageVolumeSource],
	"StorageVolumeStateUsage":                    ptr[api.StorageVolumeStateUsage],
}

type testCase struct {
	Type string `json:"type"`
	JSON string `json:"json"`
}

type result struct {
	Accepted  bool    `json:"accepted"`
	Canonical *string `json:"canonical"`
}

func main() {
	var input struct {
		Cases []testCase `json:"cases"`
	}
	if err := json.NewDecoder(os.Stdin).Decode(&input); err != nil {
		panic(err)
	}

	results := make([]result, 0, len(input.Cases))
	for _, c := range input.Cases {
		factory, ok := registry[c.Type]
		if !ok {
			fmt.Fprintln(os.Stderr, "unknown model type:", c.Type)
			os.Exit(1)
		}

		value := factory()
		if err := json.Unmarshal([]byte(c.JSON), value); err != nil {
			results = append(results, result{Accepted: false})
			continue
		}

		out, err := json.Marshal(value)
		if err != nil {
			fmt.Fprintln(os.Stderr, "canonical marshal failed for", c.Type, ":", err)
			os.Exit(1)
		}

		text := string(out)
		results = append(results, result{Accepted: true, Canonical: &text})
	}

	if err := json.NewEncoder(os.Stdout).Encode(map[string]any{"results": results}); err != nil {
		panic(err)
	}
}
