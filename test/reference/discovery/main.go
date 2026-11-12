// Native discovery/authenticated-requirement oracle only; no backend activation.
package main

import (
	"context"
	"encoding/json"
	incus "github.com/lxc/incus/v7/client"
	"os"
	"time"
)

func main() {
	var input struct {
		Socket        string `json:"socket"`
		URL           string `json:"url"`
		Certificate   string `json:"certificate"`
		Project       string `json:"project"`
		Member        string `json:"member"`
		Authenticated bool   `json:"authenticated"`
	}
	if err := json.NewDecoder(os.Stdin).Decode(&input); err != nil {
		panic(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	args := &incus.ConnectionArgs{SkipGetEvents: true}
	var client incus.InstanceServer
	var err error
	if input.Socket != "" {
		client, err = incus.ConnectIncusUnixWithContext(ctx, input.Socket, args)
	} else {
		args.TLSServerCert = input.Certificate
		client, err = incus.ConnectIncusWithContext(ctx, input.URL, args)
	}
	if err != nil {
		panic(err)
	}
	if input.Project != "" {
		client = client.UseProject(input.Project)
	}
	if input.Member != "" {
		client = client.UseTarget(input.Member)
	}
	client.RequireAuthenticated(input.Authenticated)
	info, err := client.GetConnectionInfo()
	if err != nil {
		panic(err)
	}
	_, _, err = client.GetProfile("default")
	if err != nil {
		panic(err)
	}
	if err := json.NewEncoder(os.Stdout).Encode(map[string]any{"info": info, "clustered": client.IsClustered(), "agent": client.(interface{ IsAgent() bool }).IsAgent()}); err != nil {
		panic(err)
	}
}
