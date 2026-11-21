// Fixture-only v7.0.1 standard remote enrollment/connection-info sequence.
// Calls unmodified client methods used by cmd/incus/remote.go; no real Incus.
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
	input := struct{ URL, ServerCertificate, ClientCertificate, ClientKey, Token, Fingerprint string }{}
	data, err := os.ReadFile(os.Args[1])
	must(err)
	must(json.Unmarshal(data, &input))
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	client, err := incus.ConnectIncusWithContext(ctx, input.URL, &incus.ConnectionArgs{
		TLSServerCert: input.ServerCertificate, TLSClientCert: input.ClientCertificate,
		TLSClientKey: input.ClientKey, SkipGetEvents: true,
	})
	must(err)
	defer client.Disconnect()
	before, _, err := client.GetServer()
	must(err)
	// Exactly the body `incus query PATH` sends without --data
	// (cmd/incus/query.go): "" is not JSON, so it falls back to the string.
	var queryData any
	if json.Unmarshal([]byte(""), &queryData) != nil {
		queryData = ""
	}
	queriedServer, _, err := client.RawQuery("GET", "/1.0", queryData, "")
	must(err)
	// Exactly the request `incus remote add NAME TOKEN` sends
	// (cmd/incus/remote.go addRemoteFromToken): only the token.
	must(client.CreateCertificate(api.CertificatesPost{TrustToken: input.Token}))
	after, _, err := client.GetServer()
	must(err)
	info, err := client.GetConnectionInfo()
	must(err)
	certificates, err := client.GetCertificates()
	must(err)
	queriedCertificates, _, err := client.RawQuery("GET", "/1.0/certificates?recursion=1", queryData, "")
	must(err)
	certificate, etag, err := client.GetCertificate(input.Fingerprint)
	must(err)
	certificate.Name = "updated by pinned client"
	must(client.UpdateCertificate(input.Fingerprint, certificate.Writable(), etag))
	updated, _, err := client.GetCertificate(input.Fingerprint)
	must(err)
	must(client.DeleteCertificate(input.Fingerprint))
	final, _, err := client.GetServer()
	must(err)
	must(json.NewEncoder(os.Stdout).Encode(map[string]any{
		"before": before, "after": after, "info": info, "certificates": certificates,
		"updated": updated, "final": final,
		"queried_server": queriedServer.Metadata, "queried_certificates": queriedCertificates.Metadata,
	}))
}
func must(err error) {
	if err != nil {
		panic(err)
	}
}
