// Reference driver for S06 archives: invokes the unchanged official v7.0.1 backup
// export, direct backup and backup/ISO import methods over Unix or mutual TLS.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"time"

	incus "github.com/lxc/incus/v7/client"
	"github.com/lxc/incus/v7/shared/api"
)

type Input struct {
	Socket     string          `json:"socket"`
	URL        string          `json:"url"`
	TLSCA      string          `json:"tls_ca"`
	ClientCert string          `json:"client_cert"`
	ClientKey  string          `json:"client_key"`
	Project    string          `json:"project"`
	Target     string          `json:"target"`
	Action     string          `json:"action"`
	Instance   string          `json:"instance"`
	Pool       string          `json:"pool"`
	Volume     string          `json:"volume"`
	Bucket     string          `json:"bucket"`
	Backup     string          `json:"backup"`
	Body       json.RawMessage `json:"body"`
	Name       string          `json:"name"`
	PoolName   string          `json:"pool_name"`
	Config     *[]string       `json:"config"`
	Devices    *[]string       `json:"devices"`
	Payload    []byte          `json:"payload"`
}

// sink is the in-memory io.WriteSeeker the pinned download methods write into.
type sink struct {
	bytes.Buffer
}

func (s *sink) Seek(offset int64, whence int) (int64, error) {
	if offset == 0 && whence == io.SeekCurrent {
		return int64(s.Len()), nil
	}

	return 0, errors.New("unsupported seek")
}

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: reference-archives-driver INPUT_JSON")
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

	result := map[string]any{}
	out := &sink{}
	request := &incus.BackupFileRequest{BackupFile: out}
	var file *incus.BackupFileResponse
	var op incus.Operation
	payload := bytes.NewReader(input.Payload)
	switch input.Action {
	case "GetInstanceBackupFile":
		file, err = client.GetInstanceBackupFile(input.Instance, input.Backup, request)
	case "GetStorageVolumeBackupFile":
		file, err = client.GetStorageVolumeBackupFile(input.Pool, input.Volume, input.Backup, request)
	case "GetStoragePoolBucketBackupFile":
		file, err = client.GetStoragePoolBucketBackupFile(input.Pool, input.Bucket, input.Backup, request)
	case "CreateInstanceBackupStream":
		var body api.InstanceBackupsPost
		if err = json.Unmarshal(input.Body, &body); err == nil {
			err = client.CreateInstanceBackupStream(input.Instance, body, request)
		}
	case "CreateStorageVolumeBackupStream":
		var body api.StorageVolumeBackupsPost
		if err = json.Unmarshal(input.Body, &body); err == nil {
			err = client.CreateStorageVolumeBackupStream(input.Pool, input.Volume, body, request)
		}
	case "CreateStoragePoolBucketBackupStream":
		var body api.StorageBucketBackupsPost
		if err = json.Unmarshal(input.Body, &body); err == nil {
			err = client.CreateStoragePoolBucketBackupStream(input.Pool, input.Bucket, body, request)
		}
	case "CreateInstanceFromBackup":
		backup := incus.InstanceBackupArgs{BackupFile: payload, PoolName: input.PoolName, Name: input.Name}
		if input.Config != nil {
			backup.Config = *input.Config
		}
		if input.Devices != nil {
			backup.Devices = *input.Devices
		}
		op, err = client.CreateInstanceFromBackup(backup)
	case "CreateStoragePoolVolumeFromBackup":
		op, err = client.CreateStoragePoolVolumeFromBackup(input.Pool,
			incus.StorageVolumeBackupArgs{BackupFile: payload, Name: input.Name})
	case "CreateStoragePoolVolumeFromISO":
		op, err = client.CreateStoragePoolVolumeFromISO(input.Pool,
			incus.StorageVolumeBackupArgs{BackupFile: payload, Name: input.Name})
	case "CreateStoragePoolBucketFromBackup":
		op, err = client.CreateStoragePoolBucketFromBackup(input.Pool,
			incus.StoragePoolBucketBackupArgs{BackupFile: payload, Name: input.Name})
	default:
		fmt.Fprintln(os.Stderr, "unknown action")
		os.Exit(1)
	}
	if err == nil && op == nil {
		result["bytes"] = out.Bytes()
	}
	if file != nil {
		result["size"] = file.Size
	}
	if op != nil {
		result["operation"] = op.Get()
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
