// Fixture-only driver of the unchanged native dynamic console helper.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"github.com/gorilla/websocket"
	incus "github.com/lxc/incus/v7/client"
	"github.com/lxc/incus/v7/shared/api"
	"io"
	"os"
	"time"
)

type rwc struct {
	io.Reader
	io.Writer
}

func (r *rwc) Close() error { return nil }
func main() {
	var input struct {
		Socket  string                  `json:"socket"`
		Body    api.InstanceConsolePost `json:"body"`
		Payload []byte                  `json:"payload"`
		Project string                  `json:"project"`
		Target  string                  `json:"target"`
	}
	if err := json.NewDecoder(os.Stdin).Decode(&input); err != nil {
		panic(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	client, err := incus.ConnectIncusUnixWithContext(ctx, input.Socket, &incus.ConnectionArgs{SkipGetEvents: true})
	if err != nil {
		panic(err)
	}
	defer client.Disconnect()
	client = client.UseProject(input.Project).UseTarget(input.Target)
	disconnected := make(chan bool)
	defer close(disconnected)
	controlled := make(chan error, 1)
	op, attach, err := client.ConsoleInstanceDynamic("fixture", input.Body, &incus.InstanceConsoleArgs{ConsoleDisconnect: disconnected, Control: func(conn *websocket.Conn) {
		_ = conn.SetWriteDeadline(time.Now().Add(3 * time.Second))
		controlled <- conn.WriteJSON(map[string]any{"command": "window-resize", "args": map[string]string{"width": "80", "height": "24"}})
	}})
	if err != nil {
		panic(err)
	}
	if err := <-controlled; err != nil {
		panic(err)
	}
	outputs := [][]byte{}
	for i := 0; i < 2; i++ {
		var out bytes.Buffer
		if err := attach(&rwc{Reader: bytes.NewReader(input.Payload), Writer: &out}); err != nil {
			panic(err)
		}
		outputs = append(outputs, out.Bytes())
	}
	if err := json.NewEncoder(os.Stdout).Encode(map[string]any{"operation": op.Get(), "outputs": outputs}); err != nil {
		panic(err)
	}
}
