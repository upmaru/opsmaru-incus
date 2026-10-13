// Fixture-only GetHTTPClient/DoHTTP oracle. No alternate backend discovery.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"strings"
	"time"

	incus "github.com/lxc/incus/v7/client"
)

func main() {
	var in struct {
		Socket        string            `json:"socket"`
		URL           string            `json:"url"`
		CA            string            `json:"ca"`
		Cert          string            `json:"cert"`
		Key           string            `json:"key"`
		ServerCert    string            `json:"server_cert"`
		Method        string            `json:"method"`
		Path          string            `json:"path"`
		Body          []byte            `json:"body"`
		Headers       map[string]string `json:"headers"`
		Authenticated bool              `json:"authenticated"`
		Protocol      string            `json:"protocol"`
	}
	if err := json.NewDecoder(os.Stdin).Decode(&in); err != nil {
		panic(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	args := &incus.ConnectionArgs{SkipGetServer: true, SkipGetEvents: true, TLSCA: in.CA,
		TLSClientCert: in.Cert, TLSClientKey: in.Key, TLSServerCert: in.ServerCert}
	var client incus.Server
	var err error
	if in.Protocol == "simplestreams" {
		client, err = incus.ConnectSimpleStreams(in.URL, args)
	} else if in.Protocol == "oci" {
		client, err = incus.ConnectOCI(in.URL, args)
	} else if in.Socket != "" {
		client, err = incus.ConnectIncusUnixWithContext(ctx, in.Socket, args)
	} else {
		client, err = incus.ConnectIncusWithContext(ctx, in.URL, args)
	}
	if err != nil {
		panic(err)
	}
	defer client.Disconnect()
	if native, ok := client.(incus.InstanceServer); ok {
		native.RequireAuthenticated(in.Authenticated)
	}
	handle, err := client.GetHTTPClient()
	if err != nil || handle == nil {
		panic("native HTTP client unavailable")
	}
	info, err := client.GetConnectionInfo()
	if err != nil {
		panic(err)
	}
	req, err := http.NewRequestWithContext(ctx, in.Method, strings.TrimRight(info.URL, "/")+in.Path, bytes.NewReader(in.Body))
	if err != nil {
		panic(err)
	}
	// Explicit non-replayable fixture request: DoHTTP's optional 305 replay
	// must not be mistaken for a safe general mutation retry contract.
	req.GetBody = nil
	for name, value := range in.Headers {
		req.Header.Set(name, value)
	}
	response, err := client.DoHTTP(req)
	if err != nil {
		panic(err)
	}
	defer response.Body.Close()
	body, err := io.ReadAll(io.LimitReader(response.Body, 1<<20))
	if err != nil {
		panic(err)
	}
	if err := json.NewEncoder(os.Stdout).Encode(map[string]any{"status": response.StatusCode,
		"body": body, "etag": response.Header.Get("ETag")}); err != nil {
		panic(err)
	}
}
