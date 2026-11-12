// Fixture-only extension matrix for the unchanged pinned CopyInstance helper.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"slices"
	"time"

	incus "github.com/lxc/incus/v7/client"
	"github.com/lxc/incus/v7/shared/api"
)

type source struct {
	incus.InstanceServer
	Extensions []string
}

func (s source) HasExtension(name string) bool { return slices.Contains(s.Extensions, name) }

func main() {
	var input struct {
		Socket           string                 `json:"socket"`
		SourceExtensions []string               `json:"source_extensions"`
		Options          incus.InstanceCopyArgs `json:"options"`
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
	op, err := client.CopyInstance(source{client, input.SourceExtensions}, api.Instance{Name: "fixture", Type: "container"}, &input.Options)
	result := map[string]any{}
	if err != nil {
		result["error"] = err.Error()
	} else {
		result["accepted"] = op != nil
	}
	if err := json.NewEncoder(os.Stdout).Encode(result); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
