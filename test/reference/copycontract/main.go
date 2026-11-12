// Reference driver for S10 copy orchestration: invokes the unchanged official v7.0.1
// CopyInstance, CopyInstanceSnapshot and CopyStoragePoolVolume over Unix or mutual
// TLS, then waits on or cancels the returned remote operation.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"time"

	incus "github.com/lxc/incus/v7/client"
	"github.com/lxc/incus/v7/shared/api"
)

type endpoint struct {
	Socket     string `json:"socket"`
	URL        string `json:"url"`
	TLSCA      string `json:"tls_ca"`
	ClientCert string `json:"client_cert"`
	ClientKey  string `json:"client_key"`
	Project    string `json:"project"`
	Member     string `json:"member"`
}

func connect(ctx context.Context, e endpoint) (incus.InstanceServer, error) {
	args := &incus.ConnectionArgs{SkipGetEvents: true, TLSCA: e.TLSCA,
		TLSClientCert: e.ClientCert, TLSClientKey: e.ClientKey}
	var c incus.InstanceServer
	var err error
	if e.Socket != "" {
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
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: reference-copy-contract-driver INPUT_JSON")
		os.Exit(1)
	}
	raw, err := os.ReadFile(os.Args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	var in struct {
		Action     string          `json:"action"`
		After      string          `json:"after"`
		Source     endpoint        `json:"source"`
		Target     endpoint        `json:"target"`
		Body       json.RawMessage `json:"body"`
		Options    json.RawMessage `json:"options"`
		Pool       string          `json:"pool"`
		SourcePool string          `json:"source_pool"`
		Parent     string          `json:"parent"`
	}
	if err := json.Unmarshal(raw, &in); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	target, err := connect(ctx, in.Target)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	source, err := connect(ctx, in.Source)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}

	var op incus.RemoteOperation
	switch in.Action {
	case "instance":
		var model api.Instance
		var args incus.InstanceCopyArgs
		if err = json.Unmarshal(in.Body, &model); err == nil {
			err = json.Unmarshal(in.Options, &args)
		}
		if err == nil {
			op, err = target.CopyInstance(source, model, &args)
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
	case "volume":
		var model api.StorageVolume
		var args incus.StoragePoolVolumeCopyArgs
		if err = json.Unmarshal(in.Body, &model); err == nil {
			err = json.Unmarshal(in.Options, &args)
		}
		if err == nil {
			op, err = target.CopyStoragePoolVolume(in.Pool, source, in.SourcePool, model, &args)
		}
	default:
		fmt.Fprintln(os.Stderr, "unknown action")
		os.Exit(1)
	}

	result := map[string]any{}
	if err != nil {
		result["error"] = err.Error()
	} else {
		result["accepted"] = op != nil
		switch in.After {
		case "cancel":
			// The pinned pull/push copy issues its target asynchronously; cancel once
			// the target operation exists.
			for deadline := time.Now().Add(5 * time.Second); time.Now().Before(deadline); time.Sleep(10 * time.Millisecond) {
				if _, err = op.GetTarget(); err == nil {
					break
				}
			}
			err = op.CancelTarget()
			if err != nil {
				result["error"] = err.Error()
			} else {
				result["canceled"] = true
			}
		default:
			err = op.Wait()
			if err != nil {
				result["error"] = err.Error()
			} else {
				result["completed"] = true
			}
		}
	}
	if err := json.NewEncoder(os.Stdout).Encode(result); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
