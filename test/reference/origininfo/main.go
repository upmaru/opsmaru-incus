// Private fixture-only origin metadata oracle; no requests, tools or conversions.
package main

import (
	"encoding/json"
	incus "github.com/lxc/incus/v7/client"
	"os"
)

func main() {
	var in struct{ URL, CA, Certificate, Protocol string }
	if err := json.NewDecoder(os.Stdin).Decode(&in); err != nil {
		panic(err)
	}
	// TLSServerCert is the certificate OCI connection info hands to a target.
	args := &incus.ConnectionArgs{TLSCA: in.CA, TLSServerCert: in.Certificate}
	var client incus.Server
	var err error
	if in.Protocol == "simplestreams" {
		client, err = incus.ConnectSimpleStreams(in.URL, args)
	} else if in.Protocol == "oci" {
		client, err = incus.ConnectOCI(in.URL, args)
	} else {
		panic("unsupported fixture protocol")
	}
	if err != nil {
		panic(err)
	}
	defer client.Disconnect()
	info, err := client.GetConnectionInfo()
	if err != nil {
		panic(err)
	}
	if err := json.NewEncoder(os.Stdout).Encode(info); err != nil {
		panic(err)
	}
}
