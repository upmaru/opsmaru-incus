// Native event-send oracle over an explicitly opened fake event listener on Unix or HTTPS.
package main

import (
	"context"
	"encoding/json"
	incus "github.com/lxc/incus/v7/client"
	"github.com/lxc/incus/v7/shared/api"
	"os"
	"time"
)

func main() {
	var input struct {
		Socket     string    `json:"socket"`
		URL        string    `json:"url"`
		ServerCert string    `json:"server_cert"`
		ClientCert string    `json:"client_cert"`
		ClientKey  string    `json:"client_key"`
		TLSCA      string    `json:"tls_ca"`
		Event      api.Event `json:"event"`
	}
	if err := json.NewDecoder(os.Stdin).Decode(&input); err != nil {
		panic(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	args := &incus.ConnectionArgs{SkipGetEvents: true, TLSServerCert: input.ServerCert,
		TLSClientCert: input.ClientCert, TLSClientKey: input.ClientKey, TLSCA: input.TLSCA}
	var client incus.InstanceServer
	var err error
	if input.Socket != "" {
		client, err = incus.ConnectIncusUnixWithContext(ctx, input.Socket, args)
	} else {
		client, err = incus.ConnectIncusWithContext(ctx, input.URL, args)
	}
	if err != nil {
		panic(err)
	}
	listener, err := client.GetEvents()
	if err != nil {
		panic(err)
	}
	defer listener.Disconnect()
	err = client.SendEvent(input.Event)
	out := map[string]any{"sent": err == nil}
	if err != nil {
		out["error"] = err.Error()
	}
	if err := json.NewEncoder(os.Stdout).Encode(out); err != nil {
		panic(err)
	}
}
