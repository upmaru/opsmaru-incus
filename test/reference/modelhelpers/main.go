// Fixture-only native Writable method oracle; no backend or filesystem state.
package main

import (
	"encoding/json"
	"fmt"
	"github.com/lxc/incus/v7/shared/api"
	"os"
	"reflect"
)

func main() {
	var input struct {
		Type   string          `json:"type"`
		Body   json.RawMessage `json:"body"`
		Action string          `json:"action"`
		Code   int             `json:"code"`
		Text   string          `json:"text"`
		Args   []string        `json:"args"`
	}
	if err := json.NewDecoder(os.Stdin).Decode(&input); err != nil {
		panic(err)
	}
	if input.Action == "status" {
		out := map[string]any{"name": api.StatusCode(input.Code).String(), "final": api.StatusCode(input.Code).IsFinal(), "parsed": api.StatusCodeFromString(input.Text), "active": (&api.Instance{StatusCode: api.StatusCode(input.Code)}).IsActive()}
		if err := json.NewEncoder(os.Stdout).Encode(out); err != nil {
			panic(err)
		}
		return
	}
	if input.Action == "snapshot-name" {
		parent, snapshot, isSnapshot := api.GetParentAndSnapshotName(input.Text)
		if err := json.NewEncoder(os.Stdout).Encode([]any{parent, snapshot, isSnapshot}); err != nil {
			panic(err)
		}
		return
	}
	models := map[string]any{
		"Certificate": &api.Certificate{}, "ClusterMember": &api.ClusterMember{}, "ClusterGroup": &api.ClusterGroup{},
		"Image": &api.Image{}, "Instance": &api.Instance{}, "InstanceSnapshot": &api.InstanceSnapshot{},
		"Network": &api.Network{}, "NetworkACL": &api.NetworkACL{}, "NetworkAddressSet": &api.NetworkAddressSet{},
		"NetworkForward": &api.NetworkForward{}, "NetworkIntegration": &api.NetworkIntegration{}, "NetworkLoadBalancer": &api.NetworkLoadBalancer{},
		"NetworkPeer": &api.NetworkPeer{}, "NetworkZone": &api.NetworkZone{}, "NetworkZoneRecord": &api.NetworkZoneRecord{},
		"Profile": &api.Profile{}, "Project": &api.Project{}, "Server": &api.Server{}, "StoragePool": &api.StoragePool{},
		"StorageBucket": &api.StorageBucket{}, "StorageBucketKey": &api.StorageBucketKey{}, "StorageVolume": &api.StorageVolume{}, "StorageVolumeSnapshot": &api.StorageVolumeSnapshot{},
	}
	model, ok := models[input.Type]
	if !ok {
		panic(fmt.Errorf("unsupported oracle type %s", input.Type))
	}
	if err := json.Unmarshal(input.Body, model); err != nil {
		panic(err)
	}
	if input.Action == "url" {
		method := reflect.ValueOf(model).MethodByName("URL")
		args := []reflect.Value{}
		for _, arg := range input.Args {
			args = append(args, reflect.ValueOf(arg))
		}
		out := method.Call(args)[0].Interface().(*api.URL).String()
		if err := json.NewEncoder(os.Stdout).Encode(out); err != nil {
			panic(err)
		}
		return
	}
	if input.Action == "etag" {
		out := reflect.ValueOf(model).MethodByName("Etag").Call(nil)[0].Interface()
		if err := json.NewEncoder(os.Stdout).Encode(out); err != nil {
			panic(err)
		}
		return
	}
	out := reflect.ValueOf(model).MethodByName("Writable").Call(nil)[0].Interface()
	if err := json.NewEncoder(os.Stdout).Encode(out); err != nil {
		panic(err)
	}
}
