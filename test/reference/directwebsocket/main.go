// Fixture-only unchanged DoWebsocket helper with the native transport's TLS/dial configuration.
package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/url"
	"os"
	"time"

	"github.com/gorilla/websocket"
	incus "github.com/lxc/incus/v7/client"
)

func main() {
	var in struct {
		Socket     string            `json:"socket"`
		URL        string            `json:"url"`
		CA         string            `json:"ca"`
		Cert       string            `json:"cert"`
		Key        string            `json:"key"`
		ServerCert string            `json:"server_cert"`
		Path       string            `json:"path"`
		Headers    map[string]string `json:"headers"`
	}
	if err := json.NewDecoder(os.Stdin).Decode(&in); err != nil {
		panic(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	args := &incus.ConnectionArgs{SkipGetServer: true, SkipGetEvents: true, TLSCA: in.CA,
		TLSClientCert: in.Cert, TLSClientKey: in.Key, TLSServerCert: in.ServerCert}
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
	client.RequireAuthenticated(true)
	handle, err := client.GetHTTPClient()
	if err != nil {
		panic(err)
	}
	transport, ok := handle.Transport.(*http.Transport)
	if !ok {
		panic("unsupported fixture transport")
	}
	info, err := client.GetConnectionInfo()
	if err != nil {
		panic(err)
	}
	uri, err := url.Parse(info.URL + in.Path)
	if err != nil {
		panic(err)
	}
	if uri.Scheme == "http" {
		uri.Scheme = "ws"
	} else {
		uri.Scheme = "wss"
	}
	req, err := http.NewRequestWithContext(ctx, "GET", uri.String(), nil)
	if err != nil {
		panic(err)
	}
	for name, value := range in.Headers {
		req.Header.Set(name, value)
	}
	dialer := websocket.Dialer{NetDialContext: transport.DialContext, TLSClientConfig: transport.TLSClientConfig,
		HandshakeTimeout: 3 * time.Second}
	conn, response, err := client.(*incus.ProtocolIncus).DoWebsocket(dialer, uri.String(), req)
	if err != nil {
		panic(err)
	}
	defer conn.Close()
	if err = conn.SetReadDeadline(time.Now().Add(3 * time.Second)); err != nil {
		panic(err)
	}
	kind, body, err := conn.ReadMessage()
	if err != nil {
		panic(err)
	}
	if err := json.NewEncoder(os.Stdout).Encode(map[string]any{"status": response.StatusCode,
		"etag": response.Header.Get("ETag"), "kind": kind, "body": body}); err != nil {
		panic(err)
	}
}
