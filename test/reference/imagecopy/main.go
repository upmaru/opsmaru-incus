// Reference driver for S05 image copy: invokes the unchanged official v7.0.1 CopyImage
// over mutual TLS (relay also over Unix), then waits on, or cancels and then waits on,
// the returned remote operation so the pinned cleanup (token cancellation, aliases)
// runs to completion.
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
	ServerCert string `json:"server_cert"`
	ClientCert string `json:"client_cert"`
	ClientKey  string `json:"client_key"`
	Project    string `json:"project"`
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
	source, err := connect(ctx, in.Source, in.Temp)
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
