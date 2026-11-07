// Fixture-only callers of the unchanged Incus v7.0.1 migration client methods.
// The server dial mode mirrors incusd/migration_connection.go's pinned TLS
// constructor and anonymous WebSocket dial; it is not an Incus workload server.
package main

import (
	"context"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"net/url"
	"os"
	"time"

	"github.com/gorilla/websocket"
	incus "github.com/lxc/incus/v7/client"
	"github.com/lxc/incus/v7/shared/api"
	localtls "github.com/lxc/incus/v7/shared/tls"
)

type endpoint struct{ URL, Certificate, ClientCertificate, ClientKey, Project string }
type input struct {
	Action, Mode, Parent         string
	Source, Target               endpoint
	Body                         json.RawMessage
	Operation, Certificate, Name string
	Websockets                   map[string]string
}

func connect(ctx context.Context, e endpoint) (incus.InstanceServer, error) {
	c, err := incus.ConnectIncusWithContext(ctx, e.URL, &incus.ConnectionArgs{SkipGetEvents: true,
		TLSServerCert: e.Certificate, TLSClientCert: e.ClientCertificate, TLSClientKey: e.ClientKey})
	if err != nil {
		return nil, err
	}
	if e.Project != "" {
		c = c.UseProject(e.Project)
	}
	return c, nil
}
func server(in input) (map[string]any, error) {
	block, _ := pem.Decode([]byte(in.Certificate))
	if block == nil {
		return nil, fmt.Errorf("invalid pinned certificate")
	}
	cert, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		return nil, err
	}
	config, err := localtls.GetTLSConfig(cert)
	if err != nil {
		return nil, err
	}
	dialer := websocket.Dialer{TLSClientConfig: config, NetDialContext: localtls.RFC3493Dialer, HandshakeTimeout: 3 * time.Second}
	frames := map[string]string{}
	for channel, secret := range in.Websockets {
		uri, err := url.Parse(in.Operation + "/websocket")
		if err != nil {
			return nil, err
		}
		uri.Scheme = "wss"
		query := uri.Query()
		query.Set("secret", secret)
		uri.RawQuery = query.Encode()
		conn, _, err := dialer.Dial(uri.String(), nil)
		if err != nil {
			return nil, err
		}
		conn.SetReadDeadline(time.Now().Add(3 * time.Second))
		err = conn.WriteMessage(websocket.BinaryMessage, []byte(in.Name+":"+channel))
		if err != nil {
			conn.Close()
			return nil, err
		}
		_, data, err := conn.ReadMessage()
		conn.Close()
		if err != nil {
			return nil, err
		}
		frames[channel] = string(data)
	}
	return map[string]any{"frames": frames}, nil
}
func run(in input) (map[string]any, error) {
	if in.Action == "server" {
		return server(in)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	source, err := connect(ctx, in.Source)
	if err != nil {
		return nil, err
	}
	defer source.Disconnect()
	target, err := connect(ctx, in.Target)
	if err != nil {
		return nil, err
	}
	defer target.Disconnect()
	sourceInfo, err := source.GetConnectionInfo()
	if err != nil {
		return nil, err
	}
	targetInfo, err := target.GetConnectionInfo()
	if err != nil {
		return nil, err
	}
	result := map[string]any{"source_info": sourceInfo, "target_info": targetInfo}
	var op incus.RemoteOperation
	if in.Action == "snapshot" {
		var model api.InstanceSnapshot
		err = json.Unmarshal(in.Body, &model)
		if err == nil {
			op, err = target.CopyInstanceSnapshot(source, in.Parent, model, &incus.InstanceSnapshotCopyArgs{Name: "copied", Mode: in.Mode})
		}
	} else {
		var model api.Instance
		err = json.Unmarshal(in.Body, &model)
		if err == nil {
			op, err = target.CopyInstance(source, model, &incus.InstanceCopyArgs{Name: "copied", Mode: in.Mode})
		}
	}
	if err != nil {
		result["error"] = err.Error()
		return result, nil
	}
	result["accepted"] = true
	if err = op.Wait(); err != nil {
		result["error"] = err.Error()
	} else {
		result["completed"] = true
	}
	return result, nil
}
func main() {
	raw, err := os.ReadFile(os.Args[1])
	if err != nil {
		panic(err)
	}
	var in input
	if err = json.Unmarshal(raw, &in); err != nil {
		panic(err)
	}
	result, err := run(in)
	if err != nil {
		result = map[string]any{"error": err.Error()}
	}
	if err = json.NewEncoder(os.Stdout).Encode(result); err != nil {
		panic(err)
	}
}
