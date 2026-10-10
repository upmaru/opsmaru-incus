// Fixture-only calls of unchanged pinned native move/copy helpers.
package main

import (
	"context"
	"encoding/json"
	incus "github.com/lxc/incus/v7/client"
	"github.com/lxc/incus/v7/shared/api"
	"os"
	"time"
)

type endpoint struct {
	Socket      string `json:"socket"`
	URL         string `json:"url"`
	Certificate string `json:"certificate"`
	Project     string `json:"project"`
	Member      string `json:"member"`
}

func connect(ctx context.Context, e endpoint) (incus.InstanceServer, error) {
	args := &incus.ConnectionArgs{SkipGetEvents: true, TLSServerCert: e.Certificate}
	var c incus.InstanceServer
	var err error
	if e.Socket != "" {
		args.TLSServerCert = ""
		c, err = incus.ConnectIncusUnixWithContext(ctx, e.Socket, args)
	} else {
		c, err = incus.ConnectIncusWithContext(ctx, e.URL, args)
	}
	if err != nil {
		return nil, err
	}
	if e.Project != "" {
		c = c.UseProject(e.Project)
	}
	if e.Member != "" {
		c = c.UseTarget(e.Member)
	}
	return c, nil
}
func main() {
	var in struct {
		Action     string          `json:"action"`
		Source     endpoint        `json:"source"`
		Target     endpoint        `json:"target"`
		Body       json.RawMessage `json:"body"`
		Options    json.RawMessage `json:"options"`
		Pool       string          `json:"pool"`
		SourcePool string          `json:"source_pool"`
		Parent     string          `json:"parent"`
		Image      api.Image       `json:"image"`
	}
	if err := json.NewDecoder(os.Stdin).Decode(&in); err != nil {
		panic(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	target, err := connect(ctx, in.Target)
	if err != nil {
		panic(err)
	}
	source := target
	if in.Action != "move" {
		source, err = connect(ctx, in.Source)
		if err != nil {
			panic(err)
		}
	}
	var op incus.RemoteOperation
	switch in.Action {
	case "create-image":
		var req api.InstancesPost
		if err = json.Unmarshal(in.Body, &req); err == nil {
			op, err = target.CreateInstanceFromImage(source, in.Image, req)
		}
	case "rebuild-image":
		var req api.InstanceRebuildPost
		if err = json.Unmarshal(in.Body, &req); err == nil {
			op, err = target.RebuildInstanceFromImage(source, in.Image, in.Parent, req)
		}
	case "move":
		var model api.StorageVolume
		var args incus.StoragePoolVolumeMoveArgs
		if err = json.Unmarshal(in.Body, &model); err == nil {
			err = json.Unmarshal(in.Options, &args)
		}
		if err == nil {
			op, err = target.MoveStoragePoolVolume(in.Pool, source, in.SourcePool, model, &args)
		}
	case "volume":
		var model api.StorageVolume
		var args incus.StoragePoolVolumeCopyArgs
		if err = json.Unmarshal(in.Body, &model); err == nil {
			err = json.Unmarshal(in.Options, &args)
		}
		if err == nil {
			op, err = target.CopyStoragePoolVolume(in.Pool, source, in.SourcePool, model, &args)
		}
	case "snapshot":
		var model api.InstanceSnapshot
		var args incus.InstanceSnapshotCopyArgs
		if err = json.Unmarshal(in.Body, &model); err == nil {
			err = json.Unmarshal(in.Options, &args)
		}
		if err == nil {
			op, err = target.CopyInstanceSnapshot(source, in.Parent, model, &args)
		}
	case "instance":
		var model api.Instance
		var args incus.InstanceCopyArgs
		if err = json.Unmarshal(in.Body, &model); err == nil {
			err = json.Unmarshal(in.Options, &args)
		}
		if err == nil {
			op, err = target.CopyInstance(source, model, &args)
		}
	}
	result := map[string]any{}
	if err != nil {
		result["error"] = err.Error()
	} else {
		result["accepted"] = op != nil
		if op != nil {
			err = op.Wait()
			if err != nil {
				result["error"] = err.Error()
			} else {
				result["completed"] = true
			}
		}
	}
	if err := json.NewEncoder(os.Stdout).Encode(result); err != nil {
		panic(err)
	}
}
