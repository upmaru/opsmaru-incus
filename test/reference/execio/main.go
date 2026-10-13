// Fixture-only actual ExecInstance IO against unchanged Incus v7.0.1.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"time"

	incus "github.com/lxc/incus/v7/client"
	"github.com/lxc/incus/v7/shared/api"
)

func main() {
	var in struct {
		Socket, URL, CA, Cert, Key, Project, Member string
		Stdin                                       []byte
		Body                                        api.InstanceExecPost
	}
	if err := json.NewDecoder(os.Stdin).Decode(&in); err != nil {
		panic(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	args := &incus.ConnectionArgs{SkipGetEvents: true, TLSCA: in.CA,
		TLSClientCert: in.Cert, TLSClientKey: in.Key}
	var client incus.InstanceServer
	var err error
	if in.Socket != "" {
		client, err = incus.ConnectIncusUnixWithContext(ctx, in.Socket, args)
	} else {
		client, err = incus.ConnectIncusWithContext(ctx, in.URL, args)
	}
	if err != nil {
		panic(err)
	}
	defer client.Disconnect()
	client = client.UseProject(in.Project).UseTarget(in.Member)
	var stdout, stderr bytes.Buffer
	done := make(chan bool)
	op, err := client.ExecInstance("fixture", in.Body, &incus.InstanceExecArgs{
		Stdin: bytes.NewReader(in.Stdin), Stdout: &stdout, Stderr: &stderr, DataDone: done})
	result := map[string]any{}
	if err == nil {
		select {
		case <-done:
		case <-ctx.Done():
			panic("fixture IO deadline")
		}
		err = op.WaitContext(ctx)
		result["operation"] = op.Get()
		result["stdout"] = stdout.Bytes()
		result["stderr"] = stderr.Bytes()
	}
	if err != nil {
		result["error"] = err.Error()
	}
	if err := json.NewEncoder(os.Stdout).Encode(result); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
