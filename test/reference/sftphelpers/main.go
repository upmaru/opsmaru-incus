// Fixture-only driver of unchanged Incus SFTP helpers. Stdin/stdout and the
// explicitly supplied private Unix/TLS fixture only; no local file operations.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"time"

	incus "github.com/lxc/incus/v7/client"
	"github.com/pkg/sftp"
)

func main() {
	var in struct {
		Socket, URL, CA, Cert, Key, Kind, Name, Pool, VolumeType, Project, Target string
		Extensions                                                                []string
		Steps                                                                     []struct {
			Op, Path, Mode string
			Offset         int64
			Count          int
			Data           []byte
		}
	}
	if err := json.NewDecoder(os.Stdin).Decode(&in); err != nil {
		panic(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	args := &incus.ConnectionArgs{SkipGetEvents: true, TLSCA: in.CA,
		TLSClientCert: in.Cert, TLSClientKey: in.Key}
	var server incus.InstanceServer
	var err error
	if in.Socket != "" {
		server, err = incus.ConnectIncusUnixWithContext(ctx, in.Socket, args)
	} else {
		server, err = incus.ConnectIncusWithContext(ctx, in.URL, args)
	}
	if err != nil {
		panic(err)
	}
	defer server.Disconnect()
	if in.Project != "" {
		server = server.UseProject(in.Project)
	}
	if in.Target != "" {
		server = server.UseTarget(in.Target)
	}
	var client *sftp.Client
	if in.Kind == "volume" {
		client, err = server.GetStoragePoolVolumeFileSFTP(in.Pool, in.VolumeType, in.Name)
	} else {
		client, err = server.GetInstanceFileSFTP(in.Name)
	}
	result := map[string]any{"accepted": err == nil}
	if err != nil {
		result["error"] = err.Error()
	} else {
		extensions := map[string]any{}
		for _, name := range in.Extensions {
			value, found := client.HasExtension(name)
			extensions[name] = map[string]any{"found": found, "data": []byte(value)}
		}
		result["extensions"] = extensions
		steps := []map[string]any{}
		var file *sftp.File
		for _, step := range in.Steps {
			r := map[string]any{"op": step.Op}
			err = nil
			switch step.Op {
			case "open":
				flags := map[string]int{"read": os.O_RDONLY, "write": os.O_WRONLY,
					"read_write": os.O_RDWR, "append": os.O_WRONLY | os.O_APPEND,
					"create": os.O_RDWR | os.O_CREATE | os.O_TRUNC}
				file, err = client.OpenFile(step.Path, flags[step.Mode])
			case "read":
				data := make([]byte, step.Count)
				n, readErr := file.ReadAt(data, step.Offset)
				err = readErr
				r["data"] = data[:n]
			case "write":
				n, writeErr := file.WriteAt(step.Data, step.Offset)
				err = writeErr
				r["count"] = n
			case "close_file":
				err = file.Close()
			default:
				panic("unsupported fixture operation")
			}
			r["ok"] = err == nil
			if err != nil {
				r["error"] = err.Error()
				var status *sftp.StatusError
				if errors.As(err, &status) {
					r["code"] = status.Code
				}
			}
			steps = append(steps, r)
			if err != nil && step.Op == "open" {
				break
			}
		}
		result["steps"] = steps
		result["close_ok"] = client.Close() == nil
		_ = client.Wait()
	}
	if err := json.NewEncoder(os.Stdout).Encode(result); err != nil {
		panic(err)
	}
}
