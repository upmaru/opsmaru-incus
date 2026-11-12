// Native file/archive helper oracle. Only disposable fixture data/files.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	incus "github.com/lxc/incus/v7/client"
	"github.com/lxc/incus/v7/shared/api"
	"io"
	"os"
	"time"
)

func main() {
	var in struct {
		Socket  string `json:"socket"`
		Action  string `json:"action"`
		Project string `json:"project"`
		Member  string `json:"member"`
		Root    string `json:"root"`
		Payload []byte `json:"payload"`
	}
	if err := json.NewDecoder(os.Stdin).Decode(&in); err != nil {
		panic(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	client, err := incus.ConnectIncusUnixWithContext(ctx, in.Socket, &incus.ConnectionArgs{SkipGetEvents: true})
	if err != nil {
		panic(err)
	}
	client = client.UseProject(in.Project)
	if in.Member != "" {
		client = client.UseTarget(in.Member)
	}
	file, err := os.CreateTemp(in.Root, "native-archive-")
	if err != nil {
		panic(err)
	}
	defer os.Remove(file.Name())
	defer file.Close()
	req := &incus.BackupFileRequest{BackupFile: file}
	out := map[string]any{}
	var op incus.Operation
	switch in.Action {
	case "volume-read":
		var reader io.ReadCloser
		var info *incus.InstanceFileResponse
		reader, info, err = client.GetStorageVolumeFile("pool +", "custom", "volume +", "/path +")
		if err == nil {
			out["info"] = info
			if reader != nil {
				defer reader.Close()
				out["bytes"], err = io.ReadAll(io.LimitReader(reader, 1048577))
			}
		}
	case "volume-create":
		err = client.CreateStorageVolumeFile("pool +", "custom", "volume +", "/path +", incus.InstanceFileArgs{Content: bytes.NewReader(in.Payload), UID: 7, GID: 8, Mode: 0640, Type: "file", WriteMode: "overwrite"})
	case "volume-delete":
		err = client.DeleteStorageVolumeFile("pool +", "custom", "volume +", "/path +")
	case "instance-export":
		_, err = client.GetInstanceBackupFile("instance +", "backup +", req)
	case "volume-export":
		_, err = client.GetStorageVolumeBackupFile("pool +", "volume +", "backup +", req)
	case "bucket-export":
		_, err = client.GetStoragePoolBucketBackupFile("pool +", "bucket +", "backup +", req)
	case "instance-direct":
		err = client.CreateInstanceBackupStream("instance +", api.InstanceBackupsPost{Name: "native"}, req)
	case "volume-direct":
		err = client.CreateStorageVolumeBackupStream("pool +", "volume +", api.StorageVolumeBackupsPost{Name: "native"}, req)
	case "bucket-direct":
		err = client.CreateStoragePoolBucketBackupStream("pool +", "bucket +", api.StorageBucketBackupsPost{Name: "native"}, req)
	case "volume-import":
		op, err = client.CreateStoragePoolVolumeFromBackup("pool +", incus.StorageVolumeBackupArgs{BackupFile: bytes.NewReader(in.Payload), Name: "native"})
	case "iso-import":
		op, err = client.CreateStoragePoolVolumeFromISO("pool +", incus.StorageVolumeBackupArgs{BackupFile: bytes.NewReader(in.Payload), Name: "native"})
	case "bucket-import":
		op, err = client.CreateStoragePoolBucketFromBackup("pool +", incus.StoragePoolBucketBackupArgs{BackupFile: bytes.NewReader(in.Payload), Name: "native"})
	}
	if err != nil {
		out["error"] = err.Error()
	} else {
		if op != nil {
			out["operation"] = op.Get()
		}
		if in.Action != "volume-read" {
			if _, err = file.Seek(0, 0); err != nil {
				panic(err)
			}
			out["bytes"], err = io.ReadAll(io.LimitReader(file, 1048577))
			if err != nil {
				panic(err)
			}
		}
	}
	if err := json.NewEncoder(os.Stdout).Encode(out); err != nil {
		panic(err)
	}
}
