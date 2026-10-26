// Reference driver for S04 file transfer: invokes the unchanged official v7.0.1
// instance and storage volume file methods over Unix or mutual TLS.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"time"

	incus "github.com/lxc/incus/v7/client"
	"github.com/lxc/incus/v7/shared/api"
)

type Input struct {
	Socket     string `json:"socket"`
	URL        string `json:"url"`
	TLSCA      string `json:"tls_ca"`
	ClientCert string `json:"client_cert"`
	ClientKey  string `json:"client_key"`
	Project    string `json:"project"`
	Target     string `json:"target"`
	Action     string `json:"action"`
	Instance   string `json:"instance"`
	Pool       string `json:"pool"`
	VolumeType string `json:"volume_type"`
	Volume     string `json:"volume"`
	Path       string `json:"path"`
	UID        int64  `json:"uid"`
	GID        int64  `json:"gid"`
	Mode       int    `json:"mode"`
	Type       string `json:"type"`
	WriteMode  string `json:"write_mode"`
	Payload    []byte `json:"payload"`
}

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: reference-files-driver INPUT_JSON")
		os.Exit(1)
	}
	raw, err := os.ReadFile(os.Args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	var input Input
	if err := json.Unmarshal(raw, &input); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	args := &incus.ConnectionArgs{SkipGetServer: true, SkipGetEvents: true, TLSCA: input.TLSCA,
		TLSClientCert: input.ClientCert, TLSClientKey: input.ClientKey}
	var client incus.InstanceServer
	if input.Socket != "" {
		client, err = incus.ConnectIncusUnixWithContext(ctx, input.Socket, args)
	} else {
		client, err = incus.ConnectIncusWithContext(ctx, input.URL, args)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	defer client.Disconnect()
	if input.Project != "" {
		client = client.UseProject(input.Project)
	}
	if input.Target != "" {
		client = client.UseTarget(input.Target)
	}

	fileArgs := incus.InstanceFileArgs{UID: input.UID, GID: input.GID, Mode: input.Mode, Type: input.Type,
		WriteMode: input.WriteMode}
	if input.Payload != nil {
		fileArgs.Content = bytes.NewReader(input.Payload)
	}

	result := map[string]any{}
	var reader io.ReadCloser
	var info *incus.InstanceFileResponse
	switch input.Action {
	case "GetInstanceFile":
		reader, info, err = client.GetInstanceFile(input.Instance, input.Path)
	case "CreateInstanceFile":
		err = client.CreateInstanceFile(input.Instance, input.Path, fileArgs)
	case "DeleteInstanceFile":
		err = client.DeleteInstanceFile(input.Instance, input.Path)
	case "GetStorageVolumeFile":
		reader, info, err = client.GetStorageVolumeFile(input.Pool, input.VolumeType, input.Volume, input.Path)
	case "CreateStorageVolumeFile":
		err = client.CreateStorageVolumeFile(input.Pool, input.VolumeType, input.Volume, input.Path, fileArgs)
	case "DeleteStorageVolumeFile":
		err = client.DeleteStorageVolumeFile(input.Pool, input.VolumeType, input.Volume, input.Path)
	default:
		fmt.Fprintln(os.Stderr, "unknown action")
		os.Exit(1)
	}
	if info != nil {
		result["info"] = info
	}
	if reader != nil {
		defer reader.Close()
		result["bytes"], err = io.ReadAll(io.LimitReader(reader, 1048577))
	}
	if err != nil {
		result["error"] = err.Error()
		if status, ok := api.StatusErrorMatch(err); ok {
			result["error_status"] = status
		}
	}
	if err := json.NewEncoder(os.Stdout).Encode(result); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
