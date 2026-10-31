// Reference driver for S05 image copy: invokes the unchanged official v7.0.1 CopyImage
// over mutual TLS (relay also over Unix), then waits on, or cancels and then waits on,
// the returned remote operation so the pinned cleanup (token cancellation, aliases)
// runs to completion. An OCI source (S11) is the unchanged ConnectOCI client.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/url"
	"os"
	"time"

	incus "github.com/lxc/incus/v7/client"
	"github.com/lxc/incus/v7/shared/api"
)

type endpoint struct {
	Socket     string  `json:"socket"`
	URL        string  `json:"url"`
	ServerCert string  `json:"server_cert"`
	ClientCert string  `json:"client_cert"`
	ClientKey  string  `json:"client_key"`
	Project    string  `json:"project"`
	OCI        bool    `json:"oci"`
	Metadata   []byte  `json:"metadata"`
	Rootfs     []byte  `json:"rootfs"`
	User       string  `json:"user"`
	Password   *string `json:"password"`
}

// fixtureOCI is the unchanged OCI client except for GetImageFile: the pinned
// conversion needs root, skopeo and umoci, so a relay copy gets fixture bytes.
type fixtureOCI struct {
	incus.ImageServer
	metadata, rootfs []byte
}

func (f *fixtureOCI) GetImageFile(_ string, req incus.ImageFileRequest) (*incus.ImageFileResponse, error) {
	if _, err := req.MetaFile.Write(f.metadata); err != nil {
		return nil, err
	}
	if _, err := req.RootfsFile.Write(f.rootfs); err != nil {
		return nil, err
	}
	return &incus.ImageFileResponse{MetaName: "metadata.tar.gz", RootfsName: "rootfs.tar.gz",
		MetaSize: int64(len(f.metadata)), RootfsSize: int64(len(f.rootfs))}, nil
}

func connectSource(ctx context.Context, e endpoint, temp string) (incus.ImageServer, error) {
	if !e.OCI {
		return connect(ctx, e, temp)
	}
	// Credentials ride the registry URL, escaped by net/url as a Go host would build it.
	uri, err := url.Parse(e.URL)
	if err != nil {
		return nil, err
	}
	if e.User != "" && e.Password != nil {
		uri.User = url.UserPassword(e.User, *e.Password)
	} else if e.User != "" {
		uri.User = url.User(e.User)
	}
	c, err := incus.ConnectOCI(uri.String(), &incus.ConnectionArgs{TLSServerCert: e.ServerCert, TempPath: temp})
	if err != nil {
		return nil, err
	}
	return &fixtureOCI{ImageServer: c, metadata: e.Metadata, rootfs: e.Rootfs}, nil
}

func connect(ctx context.Context, e endpoint, temp string) (incus.InstanceServer, error) {
	// The pinned server certificate is the certificate CopyImage hands the other side.
	args := &incus.ConnectionArgs{SkipGetEvents: true, TLSServerCert: e.ServerCert,
		TLSClientCert: e.ClientCert, TLSClientKey: e.ClientKey, TempPath: temp}
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
	return c, nil
}

func fail(err error) {
	fmt.Fprintln(os.Stderr, err)
	os.Exit(1)
}

func main() {
	if len(os.Args) != 2 {
		fail(fmt.Errorf("usage: reference-image-copy-driver INPUT_JSON"))
	}
	raw, err := os.ReadFile(os.Args[1])
	if err != nil {
		fail(err)
	}
	var in struct {
		After  string              `json:"after"`
		Source endpoint            `json:"source"`
		Target endpoint            `json:"target"`
		Image  api.Image           `json:"image"`
		Args   incus.ImageCopyArgs `json:"args"`
		Temp   string              `json:"temp"`
	}
	if err := json.Unmarshal(raw, &in); err != nil {
		fail(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	target, err := connect(ctx, in.Target, in.Temp)
	if err != nil {
		fail(err)
	}
	source, err := connectSource(ctx, in.Source, in.Temp)
	if err != nil {
		fail(err)
	}

	result := map[string]any{}
	op, err := target.CopyImage(source, in.Image, &in.Args)
	if err != nil {
		result["error"] = err.Error()
	} else {
		if in.After == "cancel" {
			// Pull and relay issue their target asynchronously; cancel once it exists.
			for deadline := time.Now().Add(5 * time.Second); time.Now().Before(deadline); time.Sleep(10 * time.Millisecond) {
				if _, err = op.GetTarget(); err == nil {
					break
				}
			}
			if err = op.CancelTarget(); err != nil {
				result["cancel_error"] = err.Error()
			} else {
				result["canceled"] = true
			}
		}
		if err = op.Wait(); err != nil {
			result["error"] = err.Error()
		} else {
			result["completed"] = true
		}
	}
	if err := json.NewEncoder(os.Stdout).Encode(result); err != nil {
		fail(err)
	}
}
