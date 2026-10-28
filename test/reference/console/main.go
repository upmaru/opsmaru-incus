// Reference driver for S02: invokes the unchanged official v7.0.1 ConsoleInstance or
// ConsoleInstanceDynamic over Unix or mutual TLS. The control callback sends one
// window-resize; the terminal and every attachment send Payload, then the pinned write
// barrier. After printing its result the driver keeps its connections until stdin
// closes, so the test can observe the detach close frame before the process exits.
package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"sync"
	"time"

	"github.com/gorilla/websocket"
	incus "github.com/lxc/incus/v7/client"
	"github.com/lxc/incus/v7/shared/api"
)

type endpoint struct {
	Socket     string `json:"socket"`
	URL        string `json:"url"`
	ServerCert string `json:"server_cert"`
	ClientCert string `json:"client_cert"`
	ClientKey  string `json:"client_key"`
}

// buffer is the terminal sink; the static mirror writes to it from its own goroutine.
type buffer struct {
	mu  sync.Mutex
	out bytes.Buffer
}

func (b *buffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.out.Write(p)
}

func (b *buffer) Bytes() []byte {
	b.mu.Lock()
	defer b.mu.Unlock()
	return append([]byte{}, b.out.Bytes()...)
}

type rwc struct {
	io.Reader
	io.Writer
}

func (r *rwc) Close() error { return nil }

func main() {
	stdin := bufio.NewReader(os.Stdin)
	var in struct {
		endpoint
		Mode        string                  `json:"mode"`
		Body        api.InstanceConsolePost `json:"body"`
		Payload     []byte                  `json:"payload"`
		Attachments int                     `json:"attachments"`
		Expect      int                     `json:"expect"`
		Temp        string                  `json:"temp"`
	}
	if err := json.NewDecoder(stdin).Decode(&in); err != nil {
		panic(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	args := &incus.ConnectionArgs{SkipGetEvents: true, TLSServerCert: in.ServerCert,
		TLSClientCert: in.ClientCert, TLSClientKey: in.ClientKey, TempPath: in.Temp}
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

	disconnected := make(chan bool)
	controlled := make(chan error, 1)
	console := &incus.InstanceConsoleArgs{ConsoleDisconnect: disconnected, Control: func(conn *websocket.Conn) {
		msg, _ := json.Marshal(map[string]any{"command": "window-resize", "args": map[string]string{"width": "80", "height": "24"}})
		_ = conn.SetWriteDeadline(time.Now().Add(3 * time.Second))
		controlled <- conn.WriteMessage(websocket.TextMessage, msg)
	}}
	result := map[string]any{}
	outputs := [][]byte{}
	var op incus.Operation
	if in.Mode == "static" {
		out := &buffer{}
		console.Terminal = &rwc{Reader: bytes.NewReader(in.Payload), Writer: out}
		op, err = client.ConsoleInstance("fixture", in.Body, console)
		if err == nil {
			err = <-controlled
		}
		// The static mirror runs detached; wait for the echoed bytes it reports.
		for deadline := time.Now().Add(5 * time.Second); err == nil && len(out.Bytes()) < in.Expect; {
			if time.Now().After(deadline) {
				err = fmt.Errorf("static console output deadline")
			}
			time.Sleep(5 * time.Millisecond)
		}
		outputs = append(outputs, out.Bytes())
	} else {
		var attach func(io.ReadWriteCloser) error
		op, attach, err = client.ConsoleInstanceDynamic("fixture", in.Body, console)
		if err == nil {
			err = <-controlled
		}
		for i := 0; err == nil && i < in.Attachments; i++ {
			out := &buffer{}
			err = attach(&rwc{Reader: bytes.NewReader(in.Payload), Writer: out})
			outputs = append(outputs, out.Bytes())
		}
	}
	if err != nil {
		result["error"] = err.Error()
	} else {
		result["operation"] = op.Get()
		result["outputs"] = outputs
		close(disconnected)
	}
	if err := json.NewEncoder(os.Stdout).Encode(result); err != nil {
		panic(err)
	}
	_, _ = io.Copy(io.Discard, stdin)
}
