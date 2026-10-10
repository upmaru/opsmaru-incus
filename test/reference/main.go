// Fixture-only driver of the official Incus client. Never installed in Macus.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"reflect"
	"time"

	incus "github.com/lxc/incus/v7/client"
	"github.com/lxc/incus/v7/shared/api"
)

type Input struct {
	SourceURL   string `json:"source_url"`
	SourceCert  string `json:"source_cert"`
	CopyMode    string `json:"copy_mode"`
	Transfer    string `json:"transfer"`
	Rootfs      []byte `json:"rootfs"`
	Fingerprint string `json:"fingerprint"`
	ImageType   string `json:"image_type"`

	Action      string            `json:"action"`
	Args        []json.RawMessage `json:"args"`
	Project     string            `json:"project"`
	Target      string            `json:"target"`
	Socket      string            `json:"socket"`
	URL         string            `json:"url"`
	ServerCert  string            `json:"server_cert"`
	ClientCert  string            `json:"client_cert"`
	ClientKey   string            `json:"client_key"`
	TLSCA       string            `json:"tls_ca"`
	Protocol    string            `json:"protocol"`
	Payload     []byte            `json:"payload"`
	ReadInitial int               `json:"read_initial"`
	HalfClose   bool              `json:"half_close"`
	Method      string            `json:"method"`
	Path        string            `json:"path"`
	Body        map[string]any    `json:"body"`
	ETag        string            `json:"etag"`
}

func main() {
	var input Input
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: reference-driver INPUT_JSON")
		os.Exit(1)
	}
	file, err := os.Open(os.Args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	defer file.Close()
	if err := json.NewDecoder(file).Decode(&input); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	args := &incus.ConnectionArgs{SkipGetServer: input.Protocol == "" && input.Action == "" && input.Transfer == "", SkipGetEvents: true, TLSServerCert: input.ServerCert,
		TLSClientCert: input.ClientCert, TLSClientKey: input.ClientKey, TLSCA: input.TLSCA}
	var client incus.InstanceServer
	err = nil
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
	if input.Transfer != "" {
		imageTransfer(client, input, filepath.Dir(os.Args[1]))
		return
	}
	if input.Action != "" {
		typedCall(client, input)
		return
	}
	if input.Protocol != "" {
		rawConnection(client, input)
		return
	}
	var body any
	if input.Body != nil {
		body = input.Body
	}
	response, etag, err := client.RawQuery(input.Method, input.Path, body, input.ETag)
	result := map[string]any{"response": response, "etag": etag}
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

func rawConnection(client incus.InstanceServer, input Input) {
	var conn net.Conn
	var err error
	switch input.Protocol {
	case "sftp":
		conn, err = client.GetInstanceFileSFTPConn("fixture")
	case "nbd":
		conn, err = client.GetInstanceNBDConn("fixture", incus.InstanceNBDArgs{})
	default:
		err = fmt.Errorf("unknown fixture protocol")
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(3 * time.Second))
	initial := make([]byte, input.ReadInitial)
	if _, err = io.ReadFull(conn, initial); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	result := map[string]any{"initial": initial}
	if input.HalfClose {
		probe := make([]byte, 1)
		_, err = conn.Read(probe)
		if err != io.EOF {
			fmt.Fprintln(os.Stderr, "expected half-close EOF", err)
			os.Exit(1)
		}
		result["read_eof"] = true
	}
	n, err := conn.Write(input.Payload)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	result["write_count"] = n
	if !input.HalfClose {
		echo := make([]byte, len(input.Payload))
		if _, err = io.ReadFull(conn, echo); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		result["echo"] = echo
	}
	_ = json.NewEncoder(os.Stdout).Encode(result)
}

// Reflection invokes the unchanged official method and codecs, never a wire reimplementation.
func typedCall(client incus.InstanceServer, input Input) {
	method := reflect.ValueOf(client).MethodByName(input.Action)
	if !method.IsValid() || method.Type().NumIn() != len(input.Args) {
		panic("unknown method/arity")
	}
	args := []reflect.Value{}
	normalized := []any{}
	for i, raw := range input.Args {
		value := reflect.New(method.Type().In(i))
		if err := json.Unmarshal(raw, value.Interface()); err != nil {
			panic(err)
		}
		args = append(args, value.Elem())
		normalized = append(normalized, value.Elem().Interface())
	}
	values := method.Call(args)
	result := map[string]any{"normalized_args": normalized}
	outputs := []any{}
	for _, value := range values {
		if value.Type().Implements(reflect.TypeOf((*error)(nil)).Elem()) {
			if !value.IsNil() {
				err := value.Interface().(error)
				result["error"] = err.Error()
				if status, ok := api.StatusErrorMatch(err); ok {
					result["error_status"] = status
				}
			}
		} else if operation, ok := value.Interface().(incus.Operation); ok && operation != nil {
			outputs = append(outputs, operation.Get())
		} else {
			outputs = append(outputs, value.Interface())
		}
	}
	result["outputs"] = outputs
	if err := json.NewEncoder(os.Stdout).Encode(result); err != nil {
		panic(err)
	}
}

// Reader deliberately hides length so official uploads exercise chunked framing.
type fixtureReader struct{ io.Reader }

func imageTransfer(client incus.InstanceServer, input Input, root string) {
	result := map[string]any{}
	if input.Transfer == "copy_instance_local" || input.Transfer == "copy_snapshot_local" || input.Transfer == "copy_volume_local" {
		body, _ := json.Marshal(input.Body)
		var operation incus.RemoteOperation
		var err error
		switch input.Transfer {
		case "copy_instance_local":
			var instance api.Instance
			if err = json.Unmarshal(body, &instance); err != nil { panic(err) }
			operation, err = client.CopyInstance(client, instance, &incus.InstanceCopyArgs{Name: "copy"})
		case "copy_snapshot_local":
			var snapshot api.InstanceSnapshot
			if err = json.Unmarshal(body, &snapshot); err != nil { panic(err) }
			operation, err = client.CopyInstanceSnapshot(client, "fixture", snapshot, &incus.InstanceSnapshotCopyArgs{Name: "copy"})
		case "copy_volume_local":
			var volume api.StorageVolume
			if err = json.Unmarshal(body, &volume); err != nil { panic(err) }
			operation, err = client.CopyStoragePoolVolume("target-pool", client, "source-pool", volume, &incus.StoragePoolVolumeCopyArgs{Name: "copy"})
		}
		if err == nil { err = operation.Wait() }
		if err != nil { result["error"] = err.Error() }
		_ = json.NewEncoder(os.Stdout).Encode(result)
		return
	}
	if input.Transfer == "file_read" {
		reader, response, err := client.GetInstanceFile("fixture", "/native")
		if err != nil { panic(err) }
		result["response"] = response
		if reader != nil { defer reader.Close(); result["bytes"], err = io.ReadAll(io.LimitReader(reader, 1048577)); if err != nil { panic(err) } }
		_ = json.NewEncoder(os.Stdout).Encode(result)
		return
	}
	if input.Transfer == "file_create" {
		var args incus.InstanceFileArgs
		body, _ := json.Marshal(input.Body)
		if err := json.Unmarshal(body, &args); err != nil { panic(err) }
		args.Content = bytes.NewReader(input.Payload)
		if err := client.CreateInstanceFile("fixture", "/native", args); err != nil { result["error"] = err.Error() }
		_ = json.NewEncoder(os.Stdout).Encode(result)
		return
	}
	if input.Transfer == "backup_import" {
		var args incus.InstanceBackupArgs
		body, _ := json.Marshal(input.Body)
		if err := json.Unmarshal(body, &args); err != nil { panic(err) }
		args.BackupFile = fixtureReader{bytes.NewReader(input.Payload)}
		op, err := client.CreateInstanceFromBackup(args)
		if err != nil { result["error"] = err.Error() } else { result["operation"] = op.Get() }
		_ = json.NewEncoder(os.Stdout).Encode(result)
		return
	}
	if input.Transfer == "websocket" {
		conn, err := client.RawWebsocket(input.Path)
		if err != nil {
			panic(err)
		}
		defer conn.Close()
		_ = conn.SetReadDeadline(time.Now().Add(3 * time.Second))
		kind, data, err := conn.ReadMessage()
		if err != nil {
			panic(err)
		}
		result["kind"] = kind
		result["initial"] = data
		if err := conn.WriteMessage(2, input.Payload); err != nil {
			panic(err)
		}
		_, data, err = conn.ReadMessage()
		if err != nil {
			panic(err)
		}
		result["echo"] = data
		_ = json.NewEncoder(os.Stdout).Encode(result)
		return
	}
	if input.Transfer == "copy_image" {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		source, err := incus.ConnectIncusWithContext(ctx, input.SourceURL, &incus.ConnectionArgs{TLSServerCert: input.SourceCert, SkipGetEvents: true})
		if err != nil {
			panic(err)
		}
		defer source.Disconnect()
		var image api.Image
		body, _ := json.Marshal(input.Body)
		if err := json.Unmarshal(body, &image); err != nil {
			panic(err)
		}
		operation, err := client.CopyImage(source, image, &incus.ImageCopyArgs{Mode: input.CopyMode})
		if err != nil {
			result["error"] = err.Error()
		} else {
			if err := operation.Wait(); err != nil {
				result["error"] = err.Error()
			}
		}
		_ = json.NewEncoder(os.Stdout).Encode(result)
		return
	}
	if input.Transfer == "import_image" {
		var image api.ImagesPost
		body, _ := json.Marshal(input.Body)
		if err := json.Unmarshal(body, &image); err != nil {
			panic(err)
		}
		args := &incus.ImageCreateArgs{MetaFile: fixtureReader{bytes.NewReader(input.Payload)}, MetaName: "metadata.tar", Type: input.ImageType}
		if input.Rootfs != nil {
			args.RootfsFile = fixtureReader{bytes.NewReader(input.Rootfs)}
			args.RootfsName = "rootfs.tar"
		}
		op, err := client.CreateImage(image, args)
		if err != nil {
			result["error"] = err.Error()
		} else {
			result["operation"] = op.Get()
		}
	} else {
		meta, err := os.CreateTemp(root, "meta-")
		if err != nil {
			panic(err)
		}
		defer os.Remove(meta.Name())
		defer meta.Close()
		rootfs, err := os.CreateTemp(root, "rootfs-")
		if err != nil {
			panic(err)
		}
		defer os.Remove(rootfs.Name())
		defer rootfs.Close()
		response, err := client.GetImageFile(input.Fingerprint, incus.ImageFileRequest{MetaFile: meta, RootfsFile: rootfs})
		if err != nil {
			result["error"] = err.Error()
		} else {
			result["response"] = response
			_ = meta.Close()
			_ = rootfs.Close()
			result["metadata"], _ = os.ReadFile(meta.Name())
			result["rootfs"], _ = os.ReadFile(rootfs.Name())
		}
	}
	if err := json.NewEncoder(os.Stdout).Encode(result); err != nil {
		panic(err)
	}
}
