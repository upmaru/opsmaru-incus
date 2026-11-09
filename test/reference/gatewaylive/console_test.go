package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	incus "github.com/lxc/incus/v7/client"
	"github.com/lxc/incus/v7/shared/api"
)

func TestConsoleProof(t *testing.T) {
	for _, tc := range []struct {
		name                                   string
		producerFailure, omitNonce, slowDetach bool
	}{
		{name: "nonce"}, {name: "producer-failure", producerFailure: true}, {name: "prompt-alone-is-not-proof", omitNonce: true}, {name: "detach-after-control-deadline", slowDetach: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			budget := 1500 * time.Millisecond
			if tc.slowDetach {
				budget = 5 * time.Second
			}
			ctx, cancel := context.WithTimeout(context.Background(), budget)
			defer cancel()
			var accepted, earlyWait atomic.Bool
			var execCalls atomic.Int32
			dataReady := make(chan *websocket.Conn, 1)
			nonceSeen := make(chan string, 1)
			controlClosed := make(chan error, 1)
			stopped := make(chan struct{})
			defer close(stopped)
			const consoleID = "11111111-1111-4111-8111-111111111111"
			const writerID = "22222222-2222-4222-8222-222222222222"
			respond := func(w http.ResponseWriter, kind string, metadata any) {
				_ = json.NewEncoder(w).Encode(map[string]any{"type": kind, "status_code": 200, "metadata": metadata})
			}
			server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				switch {
				case r.URL.Path == "/1.0":
					respond(w, "sync", map[string]any{"api_version": "1.0", "auth": "trusted", "api_extensions": []string{"instances", "console"}, "environment": map[string]any{}})
				case strings.HasSuffix(r.URL.Path, "/console") && r.Method == "POST":
					_ = json.NewEncoder(w).Encode(map[string]any{"type": "async", "operation": "/1.0/operations/" + consoleID, "metadata": map[string]any{"id": consoleID, "status_code": 103, "metadata": map[string]any{"fds": map[string]string{"control": "control", "0": "0"}}}})
				case strings.HasSuffix(r.URL.Path, "/websocket"):
					conn, err := (&websocket.Upgrader{}).Upgrade(w, r, nil)
					if err != nil {
						t.Error(err)
						return
					}
					defer conn.Close()
					go func() { <-stopped; _ = conn.Close() }()
					if r.URL.Query().Get("secret") == "0" {
						_ = conn.WriteMessage(websocket.BinaryMessage, []byte("unrelated login prompt\r\n"))
						dataReady <- conn
					}
					for {
						if _, _, err = conn.ReadMessage(); err != nil {
							if r.URL.Query().Get("secret") == "control" {
								controlClosed <- err
							}
							return
						}
					}
				case strings.HasSuffix(r.URL.Path, "/exec") && r.Method == "POST":
					execCalls.Add(1)
					var body api.InstanceExecPost
					if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
						t.Error(err)
						return
					}
					if body.WaitForWS || len(body.Command) != 5 || body.Command[0] != "/bin/sh" || body.Command[1] != "-c" || body.Command[2] != `printf '%s\n' "$1" > /dev/console` || body.Command[3] != "opsmaru-console-proof" || !strings.HasPrefix(body.Command[4], "opsmaru-gateway-console-") {
						t.Errorf("unexpected source-owned writer shape")
						return
					}
					nonceSeen <- body.Command[4]
					var conn *websocket.Conn
					select {
					case conn = <-dataReady:
					case <-ctx.Done():
						return
					}
					if !tc.omitNonce && !tc.producerFailure {
						nonce := []byte(body.Command[4])
						split := len(nonce) / 2
						_ = conn.WriteMessage(websocket.BinaryMessage, nonce[:split])
						_ = conn.WriteMessage(websocket.BinaryMessage, nonce[split:])
					}
					_ = json.NewEncoder(w).Encode(map[string]any{"type": "async", "operation": "/1.0/operations/" + writerID, "metadata": map[string]any{"id": writerID, "status_code": 103, "metadata": map[string]any{}}})
				case r.URL.Path == "/1.0/operations/"+writerID+"/wait":
					if !accepted.Load() {
						earlyWait.Store(true)
					}
					if tc.slowDetach {
						time.Sleep(3100 * time.Millisecond)
					}
					status, nativeErr, exit := 200, "", 0
					if tc.producerFailure {
						status, nativeErr, exit = 400, "native writer failed", 1
					}
					respond(w, "sync", map[string]any{"id": writerID, "status_code": status, "err": nativeErr, "metadata": map[string]any{"return": exit}})
				default:
					t.Errorf("unexpected native route %s %s", r.Method, r.URL.Path)
					http.NotFound(w, r)
				}
			}))
			defer server.Close()
			cert := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: server.Certificate().Raw})
			client, err := incus.ConnectIncusWithContext(ctx, server.URL, &incus.ConnectionArgs{TLSServerCert: string(cert), SkipGetEvents: true})
			if err != nil {
				t.Fatal(err)
			}
			defer client.Disconnect()
			out := map[string]any{}
			err = consoleProof(ctx, client.UseProject("owned-fixture"), "owned-fixture", out, func(_ context.Context, id, hash string) error {
				if id != writerID || len(hash) != 64 {
					t.Error("invalid accepted proof")
				}
				accepted.Store(true)
				return nil
			})
			if execCalls.Load() != 1 || earlyWait.Load() || !accepted.Load() {
				t.Fatalf("writer count/order invalid: %d %v %v", execCalls.Load(), earlyWait.Load(), accepted.Load())
			}
			nonce := <-nonceSeen
			hash := sha256.Sum256([]byte(nonce))
			if out["nonce_sha256"] != hex.EncodeToString(hash[:]) || out["writer_operation"] != writerID {
				t.Fatal("wrong nonce/operation proof")
			}
			encoded, _ := json.Marshal(out)
			if strings.Contains(string(encoded), nonce) {
				t.Fatal("plaintext nonce leaked")
			}
			if tc.producerFailure || tc.omitNonce {
				if err == nil {
					t.Fatal("native producer failure or prompt-alone was accepted")
				}
			} else if err != nil || out["received_bytes"].(int) < len(nonce) || out["local_detach"] != true || out["remote_cancel"] != false {
				t.Fatalf("console proof failed: %v %v", err, out)
			}
			if tc.slowDetach {
				select {
				case closeErr := <-controlClosed:
					if !websocket.IsCloseError(closeErr, websocket.CloseNormalClosure) {
						t.Fatalf("detach inherited temporary deadline: %v", closeErr)
					}
				case <-time.After(time.Second):
					t.Fatal("local console detach missing")
				}
			}
		})
	}
}
