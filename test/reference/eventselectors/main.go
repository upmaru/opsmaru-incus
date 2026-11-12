// Pinned event subscription selector oracle against an isolated fixture over Unix or HTTPS.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"time"

	incus "github.com/lxc/incus/v7/client"
	"github.com/lxc/incus/v7/shared/api"
)

func main() {
	var in struct {
		Action     string   `json:"action"`
		Types      []string `json:"types"`
		Project    string   `json:"project"`
		Target     string   `json:"target"`
		Socket     string   `json:"socket"`
		URL        string   `json:"url"`
		ServerCert string   `json:"server_cert"`
		ClientCert string   `json:"client_cert"`
		ClientKey  string   `json:"client_key"`
		TLSCA      string   `json:"tls_ca"`
	}
	if err := json.NewDecoder(os.Stdin).Decode(&in); err != nil {
		panic(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	args := &incus.ConnectionArgs{SkipGetEvents: true, TLSServerCert: in.ServerCert,
		TLSClientCert: in.ClientCert, TLSClientKey: in.ClientKey, TLSCA: in.TLSCA}
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
	if in.Project != "" {
		client = client.UseProject(in.Project)
	}
	if in.Target != "" {
		client = client.UseTarget(in.Target)
	}
	var listener *incus.EventListener
	switch in.Action {
	case "GetEvents":
		listener, err = client.GetEvents()
	case "GetEventsByType":
		listener, err = client.GetEventsByType(in.Types)
	case "GetEventsAllProjects":
		listener, err = client.GetEventsAllProjects()
	case "GetEventsAllProjectsByType":
		listener, err = client.GetEventsAllProjectsByType(in.Types)
	default:
		panic("unsupported action")
	}
	out := map[string]any{}
	if err != nil {
		out["error"] = err.Error()
		if status, ok := api.StatusErrorMatch(err); ok {
			out["error_status"] = status
		}
		encode(out)
		return
	}
	defer listener.Disconnect()
	seen := make(chan api.Event, 1)
	if _, err := listener.AddHandler(nil, func(e api.Event) { seen <- e }); err != nil {
		panic(err)
	}
	select {
	case event := <-seen:
		out["event"] = event
	case <-ctx.Done():
		panic(errors.New("event deadline"))
	}
	encode(out)
}

func encode(out map[string]any) {
	if err := json.NewEncoder(os.Stdout).Encode(out); err != nil {
		panic(err)
	}
}
