// Fixture-only differential driver for the official Incus v7.0.1 stream
// methods. It invokes the unchanged typed client methods (GetMetrics,
// GetNetworkACLLogfile, GetInstanceLogfile, GetInstanceConsoleLog,
// GetInstanceTemplateFile, CreateInstanceTemplateFile, GetInstanceDebugMemory)
// against a local fixture endpoint and reports bounded bytes/errors as JSON.
// It is never installed in Macus or a host runtime and starts no workload.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"time"

	incus "github.com/lxc/incus/v7/client"
	"github.com/lxc/incus/v7/shared/api"
)

type Input struct {
	Socket     string `json:"socket"`
	URL        string `json:"url"`
	ServerCert string `json:"server_cert"`
	Project    string `json:"project"`
	Target     string `json:"target"`
	Action     string `json:"action"`
	Name       string `json:"name"`
	Filename   string `json:"filename"`
	Template   string `json:"template"`
	Format     string `json:"format"`
	Payload    []byte `json:"payload"`
	ReadLimit  int    `json:"read_limit"`
}

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: reference-streams-driver INPUT_JSON")
		os.Exit(1)
	}
	file, err := os.Open(os.Args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	defer file.Close()
	var input Input
	if err := json.NewDecoder(file).Decode(&input); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	args := &incus.ConnectionArgs{SkipGetServer: true, SkipGetEvents: true, TLSServerCert: input.ServerCert}
	var client incus.InstanceServer
	if input.Socket != "" {
		client, err = incus.ConnectIncusUnixWithContext(ctx, input.Socket, args)
	} else if input.URL != "" {
		client, err = incus.ConnectIncusWithContext(ctx, input.URL, args)
	} else {
		fmt.Fprintln(os.Stderr, "fixture requires a socket or url")
		os.Exit(1)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	defer client.Disconnect()
	if input.Project != "" {
		client = client.UseProject(input.Project)
	}
	if input.Target != "" {
		client = client.UseTarget(input.Target)
	}

	limit := int64(input.ReadLimit)
	if limit <= 0 {
		limit = 1_048_577
	}

	var reader io.ReadCloser
	var callErr error
	switch input.Action {
	case "GetMetrics":
		var content string
		content, callErr = client.GetMetrics()
		reader = io.NopCloser(bytes.NewReader([]byte(content)))
	case "GetNetworkACLLogfile":
		reader, callErr = client.GetNetworkACLLogfile(input.Name)
	case "GetInstanceLogfile":
		reader, callErr = client.GetInstanceLogfile(input.Name, input.Filename)
	case "GetInstanceConsoleLog":
		reader, callErr = client.GetInstanceConsoleLog(input.Name, &incus.InstanceConsoleLogArgs{})
	case "GetInstanceTemplateFile":
		reader, callErr = client.GetInstanceTemplateFile(input.Name, input.Template)
	case "CreateInstanceTemplateFile":
		callErr = client.CreateInstanceTemplateFile(input.Name, input.Template, bytes.NewReader(input.Payload))
	case "GetInstanceDebugMemory":
		reader, callErr = client.GetInstanceDebugMemory(input.Name, input.Format)
	default:
		fmt.Fprintln(os.Stderr, "unknown fixture action "+input.Action)
		os.Exit(1)
	}

	result := map[string]any{}
	if callErr == nil && reader != nil {
		data, readErr := io.ReadAll(io.LimitReader(reader, limit))
		_ = reader.Close()
		if readErr != nil {
			fmt.Fprintln(os.Stderr, readErr)
			os.Exit(1)
		}
		result["bytes"] = data
	}
	if callErr != nil {
		result["error"] = callErr.Error()
		if status, ok := api.StatusErrorMatch(callErr); ok {
			result["error_status"] = status
		}
	}
	if err := json.NewEncoder(os.Stdout).Encode(result); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
