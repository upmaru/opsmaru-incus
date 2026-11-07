// Explicit opt-in verifier only. Every endpoint/resource is supplied by the
// source-owned acceptance runner; this program never discovers a local remote.
package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"
	incus "github.com/lxc/incus/v7/client"
	"github.com/lxc/incus/v7/shared/api"
	"github.com/pkg/sftp"
)

type input struct {
	Action, Socket, URL, ServerCert, ClientCert, ClientKey, Project string
	Name, Pool, Volume, Path, ProbeHost, ProbeURL, Operation, Token string
	ProbePort                                                       int
	Data                                                            []byte
	Keep                                                            bool
}

var secret = regexp.MustCompile(`(?i)(secret=)[^&\s]+`)
var errNBDReadOnlyUnavailable = errors.New("native NBD export did not confirm read-only")

func main() {
	if len(os.Args) != 2 {
		panic("an explicit private input file is required")
	}
	file, err := os.Open(os.Args[1])
	must(err)
	data, err := io.ReadAll(io.LimitReader(file, 2097153))
	_ = file.Close()
	must(err)
	if len(data) > 2097152 {
		panic("bounded source-owned input required")
	}
	var in input
	must(json.Unmarshal(data, &in))
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	args := &incus.ConnectionArgs{SkipGetEvents: true, TLSServerCert: in.ServerCert,
		TLSClientCert: in.ClientCert, TLSClientKey: in.ClientKey}
	if in.Action == "deny_http" {
		args.SkipGetServer = true
	}
	var client incus.InstanceServer
	if in.Socket != "" {
		client, err = incus.ConnectIncusUnixWithContext(ctx, in.Socket, args)
	} else {
		if !strings.HasPrefix(in.URL, "https://") {
			panic("an explicit HTTPS gateway is required")
		}
		client, err = incus.ConnectIncusWithContext(ctx, in.URL, args)
	}
	result := map[string]any{"action": in.Action}
	if err == nil {
		defer client.Disconnect()
		if in.Project == "" {
			panic("an explicit isolated project is required")
		}
		client = client.UseProject(in.Project)
		err = exercise(ctx, client, in, result)
	}
	if err != nil {
		result["error"] = secret.ReplaceAllString(err.Error(), "${1}[REDACTED]")
		result["error_kind"] = nativeErrorKind(err)
		if status, ok := api.StatusErrorMatch(err); ok {
			result["http_status"] = status
		}
	} else {
		result["passed"] = true
	}
	must(json.NewEncoder(os.Stdout).Encode(result))
}

func nativeErrorKind(err error) string {
	if errors.Is(err, errNBDReadOnlyUnavailable) {
		return "native_nbd_readonly_unavailable"
	}
	message := strings.ToLower(err.Error())
	if strings.Contains(message, "only supported on virtual machines") {
		return "instance_nbd_requires_vm"
	}
	if strings.Contains(message, "native console produced no data") {
		return "native_console_no_data"
	}
	if strings.Contains(message, "qemu-nbd") && (strings.Contains(message, "not found") || strings.Contains(message, "no such file")) {
		return "backend_nbd_tool_unavailable"
	}
	if strings.Contains(message, "missing the required") {
		return "native_api_extension_unavailable"
	}
	var timeout net.Error
	if errors.As(err, &timeout) && timeout.Timeout() {
		return "native_transport_timeout"
	}
	if status, ok := api.StatusErrorMatch(err); ok {
		return fmt.Sprintf("native_http_%d", status)
	}
	return "native_verifier_failure"
}

func exercise(ctx context.Context, c incus.InstanceServer, in input, out map[string]any) error {
	switch in.Action {
	case "discovery":
		server, _, err := c.GetServer()
		if err != nil {
			return err
		}
		out["auth"], out["api_version"] = server.Auth, server.APIVersion
		return nil
	case "enrollment":
		if in.Token == "" {
			return errors.New("explicit single-use host token required")
		}
		if err := c.CreateCertificate(api.CertificatesPost{TrustToken: in.Token, CertificatePut: api.CertificatePut{Type: api.CertificateTypeClient}}); err != nil {
			return err
		}
		server, _, err := c.GetServer()
		if err != nil {
			return err
		}
		out["auth"] = server.Auth
		return nil
	case "http":
		instance, etag, err := c.GetInstance(in.Name)
		if err != nil {
			return err
		}
		out["name"], out["etag"], out["status_code"] = instance.Name, etag, instance.StatusCode
		return nil
	case "deny_http":
		_, _, err := c.RawQuery("GET", "/1.0/instances", nil, "")
		return err
	case "deny_ws":
		handle, err := c.GetHTTPClient()
		if err != nil {
			return err
		}
		transport, ok := handle.Transport.(*http.Transport)
		if !ok {
			return errors.New("native HTTP transport unavailable")
		}
		u, err := url.Parse(in.URL)
		if err != nil {
			return err
		}
		u.Scheme = "wss"
		u.Path = "/1.0/events"
		u.RawQuery = url.Values{"project": []string{in.Project}}.Encode()
		request, err := http.NewRequest("GET", u.String(), nil)
		if err != nil {
			return err
		}
		dialer := websocket.Dialer{NetDialContext: transport.DialContext, TLSClientConfig: transport.TLSClientConfig, HandshakeTimeout: 5 * time.Second}
		connection, response, err := c.(*incus.ProtocolIncus).DoWebsocket(dialer, u.String(), request)
		if response != nil {
			out["http_status"] = response.StatusCode
		}
		if connection != nil {
			connection.Close()
		}
		if err == nil {
			return errors.New("denied WebSocket unexpectedly accepted")
		}
		return err
	case "binary":
		if len(in.Data) == 0 || len(in.Data) > 1048576 {
			return errors.New("bounded nonempty binary input required")
		}
		err := c.CreateInstanceFile(in.Name, in.Path, incus.InstanceFileArgs{Type: "file", Mode: 0600, Content: bytes.NewReader(in.Data)})
		if err != nil {
			return err
		}
		reader, _, err := c.GetInstanceFile(in.Name, in.Path)
		if err != nil {
			return err
		}
		defer reader.Close()
		got, err := io.ReadAll(io.LimitReader(reader, 1048577))
		if err != nil {
			return err
		}
		if !bytes.Equal(in.Data, got) {
			return errors.New("native binary transfer mismatch")
		}
		out["bytes"], out["sha256"] = len(got), hash(got)
		if in.Keep {
			return nil
		}
		return c.DeleteInstanceFile(in.Name, in.Path)
	case "readfile":
		reader, _, err := c.GetInstanceFile(in.Name, in.Path)
		if err != nil {
			return err
		}
		defer reader.Close()
		data, err := io.ReadAll(io.LimitReader(reader, 1048577))
		out["data"], out["bytes"], out["sha256"] = data, len(data), hash(data)
		return err
	case "wait":
		op, _, err := c.GetOperationWait(in.Operation, 30)
		if err != nil {
			return err
		}
		out["operation"], out["status_code"], out["native_error"] = op.ID, op.StatusCode, op.Err
		return nil
	case "probe":
		if !regexp.MustCompile(`\A[a-zA-Z0-9.-]{1,253}\z`).MatchString(in.ProbeHost) || in.ProbePort < 1 || in.ProbePort > 65535 {
			return errors.New("invalid explicit gateway probe target")
		}
		var stdout, stderr bytes.Buffer
		done := make(chan bool)
		if !strings.HasPrefix(in.ProbeURL, "http://"+in.ProbeHost+":"+fmt.Sprint(in.ProbePort)+"/") {
			return errors.New("invalid controlled probe URL")
		}
		op, err := c.ExecInstance(in.Name, api.InstanceExecPost{Command: []string{"sh", "-c", `getent hosts "$1"; wget -q -T 3 -O - "$2"`, "gateway-probe", in.ProbeHost, in.ProbeURL}, WaitForWS: true}, &incus.InstanceExecArgs{Stdout: &stdout, Stderr: &stderr, DataDone: done})
		if err != nil {
			return err
		}
		if err = op.Wait(); err != nil {
			return err
		}
		select {
		case <-done:
		case <-time.After(5 * time.Second):
			return errors.New("probe output deadline")
		}
		out["operation"], out["exit"], out["stdout"], out["stderr"] = op.Get().ID, op.Get().Metadata["return"], stdout.String(), stderr.String()
		return nil
	case "exec", "events", "interrupt":
		var listener *incus.EventListener
		event := make(chan api.Event, 8)
		if in.Action == "events" {
			var err error
			listener, err = c.GetEvents()
			if err != nil {
				return err
			}
			defer listener.Disconnect()
			_, err = listener.AddHandler([]string{"operation"}, func(e api.Event) {
				select {
				case event <- e:
				default:
				}
			})
			if err != nil {
				return err
			}
		}
		command := []string{"sh", "-c", "printf 'gateway-native\\n'; printf 'gateway-stderr\\n' >&2; exit 7"}
		if in.Action == "interrupt" {
			if !regexp.MustCompile(`\A/tmp/opsmaru-gateway-interruption-[0-9a-f]{32}\z`).MatchString(in.Path) {
				return errors.New("explicit owned interruption counter required")
			}
			command = []string{"sh", "-c", `printf x >> "$1"; sleep 2`, "gateway-interruption", in.Path}
		}
		var stdout, stderr bytes.Buffer
		done := make(chan bool)
		op, err := c.ExecInstance(in.Name, api.InstanceExecPost{Command: command, WaitForWS: true},
			&incus.InstanceExecArgs{Stdin: bytes.NewReader(nil), Stdout: &stdout, Stderr: &stderr, DataDone: done})
		if err != nil {
			return err
		}
		out["operation"] = op.Get().ID
		if in.Action == "interrupt" {
			// The parent journals this identity before deliberately losing the
			// frontend process. No Cancel/DELETE/retry is issued by this driver.
			must(json.NewEncoder(os.Stdout).Encode(map[string]any{"accepted": true, "operation": op.Get().ID}))
			_, _ = io.Copy(io.Discard, os.Stdin)
			os.Exit(0)
		}
		if err = op.Wait(); err != nil {
			return err
		}
		select {
		case <-done:
		case <-time.After(5 * time.Second):
			return errors.New("native exec data completion timeout")
		}
		out["exit"], out["stdout"], out["stderr"] = op.Get().Metadata["return"], stdout.Bytes(), stderr.Bytes()
		if stdout.String() != "gateway-native\n" || stderr.String() != "gateway-stderr\n" {
			return errors.New("native exec output mismatch")
		}
		if in.Action == "events" {
			deadline := time.After(5 * time.Second)
			for {
				select {
				case e := <-event:
					var metadata struct {
						ID string `json:"id"`
					}
					_ = json.Unmarshal(e.Metadata, &metadata)
					if metadata.ID == op.Get().ID {
						out["event_operation"] = metadata.ID
						return nil
					}
				case <-deadline:
					return errors.New("native matching operation event timeout")
				}
			}
		}
		return nil
	case "console":
		return consoleProof(ctx, c, in.Name, out, acknowledgeConsoleWriter)
	case "sftp_instance", "sftp_volume":
		// The actual pkg/sftp client is returned by the unchanged Incus helper.
		var client *sftp.Client
		var err error
		if in.Action == "sftp_volume" {
			client, err = c.GetStoragePoolVolumeFileSFTP(in.Pool, "custom", in.Volume)
		} else {
			client, err = c.GetInstanceFileSFTP(in.Name)
		}
		if err != nil {
			return err
		}
		defer client.Close()
		file, err := client.OpenFile(in.Path, os.O_CREATE|os.O_TRUNC|os.O_RDWR)
		if err != nil {
			return err
		}
		if _, err = file.Write(in.Data); err != nil {
			_ = file.Close()
			return err
		}
		if _, err = file.Seek(0, io.SeekStart); err != nil {
			_ = file.Close()
			return err
		}
		got, err := io.ReadAll(io.LimitReader(file, 1048577))
		closeErr := file.Close()
		if err != nil {
			return err
		}
		if closeErr != nil {
			return closeErr
		}
		if !bytes.Equal(got, in.Data) {
			return errors.New("native SFTP binary mismatch")
		}
		out["bytes"], out["sha256"] = len(got), hash(got)
		return client.Remove(in.Path)
	case "nbd_instance", "nbd_volume":
		var conn net.Conn
		var err error
		if in.Action == "nbd_instance" {
			conn, err = c.GetInstanceNBDConn(in.Name, incus.InstanceNBDArgs{})
		} else {
			conn, err = c.GetStoragePoolVolumeBlockNBDConn(in.Pool, "custom", in.Volume, incus.StorageVolumeNBDPost{Writable: false})
		}
		if err != nil {
			return err
		}
		defer conn.Close()
		_ = conn.SetDeadline(time.Now().Add(8 * time.Second))
		return readNBD(conn, out)
	default:
		return errors.New("unsupported source-owned verifier action")
	}
}

func acknowledgeConsoleWriter(ctx context.Context, operation, nonceSHA string) error {
	if err := json.NewEncoder(os.Stdout).Encode(map[string]any{
		"accepted": true, "writer_operation": operation, "nonce_sha256": nonceSHA,
	}); err != nil {
		return err
	}
	// Wait for the source-owned parent to persist the identity before the native
	// operation wait. No replay or remote cancellation is issued on parent loss.
	ack := make(chan string, 1)
	go func() { line, _ := bufio.NewReader(io.LimitReader(os.Stdin, 64)).ReadString('\n'); ack <- line }()
	select {
	case line := <-ack:
		if line != "console-writer-recorded\n" {
			return errors.New("native console writer journal acknowledgement missing")
		}
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

func consoleProof(ctx context.Context, c incus.InstanceServer, name string, out map[string]any, accepted func(context.Context, string, string) error) error {
	reader, writer := io.Pipe()
	defer reader.Close()
	defer writer.Close()
	terminal := &consoleBuffer{Reader: reader}
	disconnect := make(chan bool)
	controlled := make(chan error, 1)
	op, err := c.ConsoleInstance(name, api.InstanceConsolePost{Width: 80, Height: 24}, &incus.InstanceConsoleArgs{
		Terminal: terminal, ConsoleDisconnect: disconnect, Control: func(ws *websocket.Conn) {
			_ = ws.SetWriteDeadline(time.Now().Add(3 * time.Second))
			err := ws.WriteJSON(map[string]any{"command": "window-resize", "args": map[string]string{"width": "80", "height": "24"}})
			if resetErr := ws.SetWriteDeadline(time.Time{}); err == nil {
				err = resetErr
			}
			controlled <- err
		}})
	if err != nil {
		return err
	}
	defer close(disconnect)
	out["operation"] = op.Get().ID
	select {
	case err = <-controlled:
	case <-ctx.Done():
		return ctx.Err()
	case <-time.After(5 * time.Second):
		return errors.New("native console control timeout")
	}
	if err != nil {
		return err
	}
	random := make([]byte, 32)
	if _, err = rand.Read(random); err != nil {
		return err
	}
	nonce := "opsmaru-gateway-console-" + hex.EncodeToString(random)
	hash := sha256.Sum256([]byte(nonce))
	out["nonce_sha256"] = hex.EncodeToString(hash[:])
	producer, err := c.ExecInstance(name, api.InstanceExecPost{
		Command:   []string{"/bin/sh", "-c", `printf '%s\n' "$1" > /dev/console`, "opsmaru-console-proof", nonce},
		WaitForWS: false,
	}, nil)
	if err != nil {
		return err
	}
	out["writer_operation"] = producer.Get().ID
	if err = accepted(ctx, producer.Get().ID, out["nonce_sha256"].(string)); err != nil {
		return err
	}
	if err = producer.WaitContext(ctx); err != nil {
		return err
	}
	if producer.Get().StatusCode != api.Success || producer.Get().Metadata["return"] != float64(0) {
		return errors.New("native console writer did not exit successfully")
	}
	deadline := time.NewTimer(5 * time.Second)
	defer deadline.Stop()
	ticker := time.NewTicker(20 * time.Millisecond)
	defer ticker.Stop()
	for !terminal.contains([]byte(nonce)) {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-deadline.C:
			return errors.New("native console produced no data containing proof nonce within deadline")
		case <-ticker.C:
		}
	}
	out["received_bytes"] = terminal.length()
	out["local_detach"], out["remote_cancel"] = true, false
	return nil
}

type consoleBuffer struct {
	io.Reader
	mu   sync.Mutex
	data bytes.Buffer
}

func (b *consoleBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.data.Len()+len(p) > 1048576 {
		return 0, errors.New("native console output bound")
	}
	return b.data.Write(p)
}
func (b *consoleBuffer) Close() error { return nil }
func (b *consoleBuffer) length() int  { b.mu.Lock(); defer b.mu.Unlock(); return b.data.Len() }
func (b *consoleBuffer) contains(p []byte) bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	return bytes.Contains(b.data.Bytes(), p)
}

// Read-only fixed-newstyle NBD verifier. Protocol reference:
// https://github.com/NetworkBlockDevice/nbd/blob/master/doc/proto.md
// No kernel device, qemu CLI or write/discard request is used.
func readNBD(conn net.Conn, out map[string]any) error {
	hello := make([]byte, 18)
	if _, err := io.ReadFull(conn, hello); err != nil {
		return err
	}
	if string(hello[:8]) != "NBDMAGIC" || string(hello[8:16]) != "IHAVEOPT" {
		return errors.New("native NBD greeting mismatch")
	}
	flags := binary.BigEndian.Uint16(hello[16:])
	if flags&1 == 0 {
		return errors.New("NBD fixed newstyle unavailable")
	}
	clientFlags := uint32(1)
	if flags&2 != 0 {
		clientFlags |= 2
	}
	if err := binary.Write(conn, binary.BigEndian, clientFlags); err != nil {
		return err
	}
	// NBD_OPT_GO, empty default export, request NBD_INFO_EXPORT.
	if err := binary.Write(conn, binary.BigEndian, []uint64{0x49484156454f5054}); err != nil {
		return err
	}
	if err := binary.Write(conn, binary.BigEndian, []uint32{7, 8, 0}); err != nil {
		return err
	}
	if err := binary.Write(conn, binary.BigEndian, []uint16{1, 0}); err != nil {
		return err
	}
	var size uint64
	var transmissionFlags uint16
	for replies := 0; replies < 16; replies++ {
		header := make([]byte, 20)
		if _, err := io.ReadFull(conn, header); err != nil {
			return err
		}
		if binary.BigEndian.Uint64(header[:8]) != 0x3e889045565a9 || binary.BigEndian.Uint32(header[8:12]) != 7 {
			return errors.New("NBD option response mismatch")
		}
		kind := binary.BigEndian.Uint32(header[12:16])
		length := binary.BigEndian.Uint32(header[16:])
		if length > 4096 {
			return errors.New("NBD option response bound")
		}
		payload := make([]byte, int(length))
		if _, err := io.ReadFull(conn, payload); err != nil {
			return err
		}
		if kind&0x80000000 != 0 {
			return fmt.Errorf("native NBD option rejected: %d", kind)
		}
		if kind == 3 && len(payload) == 12 && binary.BigEndian.Uint16(payload[:2]) == 0 {
			size = binary.BigEndian.Uint64(payload[2:10])
			transmissionFlags = binary.BigEndian.Uint16(payload[10:12])
		}
		if kind == 1 {
			if len(payload) != 0 {
				return errors.New("NBD ACK must be empty")
			}
			break
		}
		if replies == 15 {
			return errors.New("NBD option response count bound")
		}
	}
	if size < 512 {
		return errors.New("native NBD export too small")
	}
	if transmissionFlags&2 == 0 {
		return errNBDReadOnlyUnavailable
	}
	request := make([]byte, 28)
	binary.BigEndian.PutUint32(request, 0x25609513)
	binary.BigEndian.PutUint64(request[8:16], 0x6f6967)
	binary.BigEndian.PutUint32(request[24:], 512)
	if _, err := conn.Write(request); err != nil {
		return err
	}
	reply := make([]byte, 16)
	if _, err := io.ReadFull(conn, reply); err != nil {
		return err
	}
	if binary.BigEndian.Uint32(reply) != 0x67446698 || binary.BigEndian.Uint32(reply[4:8]) != 0 || binary.BigEndian.Uint64(reply[8:]) != 0x6f6967 {
		return errors.New("NBD read reply mismatch")
	}
	data := make([]byte, 512)
	if _, err := io.ReadFull(conn, data); err != nil {
		return err
	}
	binary.BigEndian.PutUint16(request[6:8], 2)
	binary.BigEndian.PutUint32(request[24:], 0)
	_, err := conn.Write(request)
	out["export_bytes"], out["read_bytes"], out["sha256"], out["readonly"] = size, len(data), hash(data), transmissionFlags&2 != 0
	return err
}
func hash(data []byte) string { sum := sha256.Sum256(data); return hex.EncodeToString(sum[:]) }
func must(err error) {
	if err != nil {
		panic(err)
	}
}
