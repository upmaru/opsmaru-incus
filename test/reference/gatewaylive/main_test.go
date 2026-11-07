package main

import (
	"encoding/binary"
	"io"
	"net"
	"strings"
	"testing"
	"time"
)

func TestReadNBD(t *testing.T) {
	for _, tc := range []struct {
		name  string
		flags uint16
		ack   []byte
		want  string
	}{
		{"read-only", 3, nil, ""}, {"writable", 1, nil, "read-only"}, {"nonempty-ack", 3, []byte{0}, "ACK must be empty"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			client, server := net.Pipe()
			defer client.Close()
			defer server.Close()
			_ = client.SetDeadline(time.Now().Add(3 * time.Second))
			_ = server.SetDeadline(time.Now().Add(3 * time.Second))
			done := make(chan error, 1)
			go func() {
				_, err := server.Write([]byte("NBDMAGICIHAVEOPT\x00\x03"))
				if err != nil {
					done <- err
					return
				}
				request := make([]byte, 28)
				if _, err = io.ReadFull(server, request); err != nil {
					done <- err
					return
				}
				if binary.BigEndian.Uint32(request[:4]) != 3 || binary.BigEndian.Uint32(request[12:16]) != 7 || binary.BigEndian.Uint32(request[16:20]) != 8 {
					done <- io.ErrUnexpectedEOF
					return
				}
				info := make([]byte, 12)
				binary.BigEndian.PutUint64(info[2:10], 1048576)
				binary.BigEndian.PutUint16(info[10:], tc.flags)
				reply := func(kind uint32, payload []byte) error {
					h := make([]byte, 20)
					binary.BigEndian.PutUint64(h, 0x3e889045565a9)
					binary.BigEndian.PutUint32(h[8:12], 7)
					binary.BigEndian.PutUint32(h[12:16], kind)
					binary.BigEndian.PutUint32(h[16:], uint32(len(payload)))
					_, e := server.Write(append(h, payload...))
					return e
				}
				if err = reply(3, info); err == nil {
					err = reply(1, tc.ack)
				}
				if err != nil {
					done <- err
					return
				}
				if tc.want != "" {
					done <- nil
					return
				}
				if _, err = io.ReadFull(server, request); err != nil {
					done <- err
					return
				}
				if binary.BigEndian.Uint32(request) != 0x25609513 || binary.BigEndian.Uint16(request[6:8]) != 0 || binary.BigEndian.Uint32(request[24:]) != 512 {
					done <- io.ErrUnexpectedEOF
					return
				}
				h := make([]byte, 16)
				binary.BigEndian.PutUint32(h, 0x67446698)
				copy(h[8:], request[8:16])
				_, err = server.Write(append(h, make([]byte, 512)...))
				if err == nil {
					_, err = io.ReadFull(server, request)
				}
				if err == nil && binary.BigEndian.Uint16(request[6:8]) != 2 {
					err = io.ErrUnexpectedEOF
				}
				done <- err
			}()
			out := map[string]any{}
			err := readNBD(client, out)
			if tc.want != "" {
				if err == nil || !strings.Contains(err.Error(), tc.want) {
					t.Fatalf("got %v, want %s", err, tc.want)
				}
			} else if err != nil {
				t.Fatal(err)
			}
			if e := <-done; e != nil {
				t.Fatal(e)
			}
			if tc.want == "" && (out["readonly"] != true || out["read_bytes"] != 512) {
				t.Fatalf("bad proof %v", out)
			}
		})
	}
}
