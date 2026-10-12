// Unchanged pinned request-context oracle over explicit private fixture endpoints.
// No operation cancellation, retry or automatic remote discovery is used.
package main

import (
	"context"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	incus "github.com/lxc/incus/v7/client"
	"os"
	"time"
)

func main() {
	var in struct {
		Socket, URL, CA, Cert, Key, Name, Project, Member, Mode string
		Timeout                                                 int
	}
	if err := json.NewDecoder(os.Stdin).Decode(&in); err != nil {
		panic(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(in.Timeout)*time.Millisecond)
	defer cancel()
	args := &incus.ConnectionArgs{SkipGetServer: true, SkipGetEvents: true, TLSCA: in.CA, TLSClientCert: in.Cert, TLSClientKey: in.Key}
	var client incus.InstanceServer
	var err error
	if in.Mode == "with_context" {
		if in.Socket != "" {
			client, err = incus.ConnectIncusUnix(in.Socket, args)
		} else {
			client, err = incus.ConnectIncus(in.URL, args)
		}
	} else {
		if in.Socket != "" {
			client, err = incus.ConnectIncusUnixWithContext(ctx, in.Socket, args)
		} else {
			client, err = incus.ConnectIncusWithContext(ctx, in.URL, args)
		}
	}
	if err != nil {
		panic(err)
	}
	defer client.Disconnect()
	if in.Mode == "with_context" {
		client = client.(*incus.ProtocolIncus).WithContext(ctx)
	}
	if in.Project != "" {
		client = client.UseProject(in.Project)
	}
	if in.Member != "" {
		client = client.UseTarget(in.Member)
	}
	if in.Mode == "canceled" {
		cancel()
	}
	profile, etag, err := client.GetProfile(in.Name)
	out := map[string]any{"profile": profile, "etag": etag}
	if err != nil {
		out["error"] = err.Error()
		// Public certificate diagnostics only, to distinguish fixture generation
		// from a served-chain mismatch. Never include private-key material.
		var verify *tls.CertificateVerificationError
		if errors.As(err, &verify) {
			diagnostic := map[string]any{}
			if len(verify.UnverifiedCertificates) > 0 {
				diagnostic["served_leaf_sha256"] = fmt.Sprintf("%x", sha256.Sum256(verify.UnverifiedCertificates[0].Raw))
			}
			block, _ := pem.Decode([]byte(in.Cert))
			if block != nil {
				diagnostic["fixture_leaf_sha256"] = fmt.Sprintf("%x", sha256.Sum256(block.Bytes))
				leaf, parseErr := x509.ParseCertificate(block.Bytes)
				roots := x509.NewCertPool()
				roots.AppendCertsFromPEM([]byte(in.CA))
				if parseErr == nil {
					_, checkErr := leaf.Verify(x509.VerifyOptions{Roots: roots, DNSName: "localhost"})
					if checkErr != nil {
						diagnostic["fixture_verify_error"] = checkErr.Error()
					}
				}
			}
			out["certificate_diagnostic"] = diagnostic
		}
	}
	if err := json.NewEncoder(os.Stdout).Encode(out); err != nil {
		panic(err)
	}
}
