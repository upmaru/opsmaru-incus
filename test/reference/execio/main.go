// Fixture-only actual ExecInstance IO against unchanged Incus v7.0.1.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"time"

	"github.com/gorilla/websocket"
	incus "github.com/lxc/incus/v7/client"
	"github.com/lxc/incus/v7/shared/api"
)

func main() {
	var in struct {
		Socket, URL, CA, Cert, Key, Project, Member, Mode string
		Stdin                                             []byte
		Body                                              api.InstanceExecPost
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
	control := make(chan bool)
	execArgs := &incus.InstanceExecArgs{
		Stdin: bytes.NewReader(in.Stdin), Stdout: &stdout, Stderr: &stderr, DataDone: done}
	switch in.Mode {
	case "submit":
		// Non-waiting or record-output submission without host IO.
		execArgs = nil
	case "interactive":
		// One PTY channel plus the native control messages the incus CLI sends.
		execArgs.Stderr = nil
		execArgs.Control = func(conn *websocket.Conn) {
			defer close(control)
			_ = conn.WriteJSON(api.InstanceExecControl{Command: "window-resize",
				Args: map[string]string{"width": "80", "height": "24"}})
			_ = conn.WriteJSON(api.InstanceExecControl{Command: "signal", Signal: 15})
		}
	}
	op, err := client.ExecInstance("fixture", in.Body, execArgs)
	result := map[string]any{}
	if err == nil && execArgs == nil {
		result["operation"] = op.Get()
	} else if err == nil {
		for _, ch := range []chan bool{done, control} {
			if ch == control && execArgs.Control == nil {
				continue
			}
			select {
			case <-ch:
			case <-ctx.Done():
				panic("fixture IO deadline")
			}
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
