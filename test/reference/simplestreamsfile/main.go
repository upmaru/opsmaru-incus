// Fixture-only oracle. Calls the unmodified pinned Incus SimpleStreams client's
// GetImages and GetImageFile against an explicitly supplied private TLS fixture,
// with an optional cache directory and delta sources. Never contacts a public
// server; deltas run whatever xdelta3 the caller puts first on PATH.
package main

import (
	"encoding/base64"
	"encoding/json"
	"io"
	"os"
	"time"

	incus "github.com/lxc/incus/v7/client"
)

func main() {
	var in struct {
		Action, URL, Certificate, CachePath, Fingerprint, Temp string
		CacheExpiry                                            int64
		Meta, Rootfs                                           bool
		Delta                                                  map[string]string
	}
	if err := json.NewDecoder(os.Stdin).Decode(&in); err != nil {
		panic(err)
	}
	args := &incus.ConnectionArgs{
		TLSServerCert: in.Certificate,
		CachePath:     in.CachePath,
		CacheExpiry:   time.Duration(in.CacheExpiry),
		TempPath:      in.Temp,
	}
	client, err := incus.ConnectSimpleStreams(in.URL, args)
	if err != nil {
		panic(err)
	}
	out := map[string]any{}
	switch in.Action {
	case "images":
		images, err := client.GetImages()
		if err != nil {
			out["error"] = err.Error()
			break
		}
		fingerprints := []string{}
		for _, image := range images {
			fingerprints = append(fingerprints, image.Fingerprint)
		}
		out["fingerprints"] = fingerprints
	case "file":
		req := incus.ImageFileRequest{}
		var meta, rootfs *os.File
		if in.Meta {
			meta = temp(in.Temp)
			req.MetaFile = meta
		}
		if in.Rootfs {
			rootfs = temp(in.Temp)
			req.RootfsFile = rootfs
		}
		if in.Delta != nil {
			req.DeltaSourceRetriever = func(fingerprint string, file string) string {
				if file != "rootfs" {
					panic("unexpected delta file " + file)
				}
				return in.Delta[fingerprint]
			}
		}
		resp, err := client.GetImageFile(in.Fingerprint, req)
		if err != nil {
			out["error"] = err.Error()
			break
		}
		out["response"] = resp
		out["meta"] = contents(meta)
		out["rootfs"] = contents(rootfs)
	default:
		panic("unknown action " + in.Action)
	}
	if err := json.NewEncoder(os.Stdout).Encode(out); err != nil {
		panic(err)
	}
}

func temp(dir string) *os.File {
	file, err := os.CreateTemp(dir, "oracle_")
	if err != nil {
		panic(err)
	}
	return file
}

func contents(file *os.File) string {
	if file == nil {
		return ""
	}
	if _, err := file.Seek(0, io.SeekStart); err != nil {
		panic(err)
	}
	bytes, err := io.ReadAll(file)
	if err != nil {
		panic(err)
	}
	return base64.StdEncoding.EncodeToString(bytes)
}
