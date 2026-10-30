// Fixture-only driver of the unchanged pinned GetInstanceFileSFTP and
// GetStoragePoolVolumeFileSFTP helpers. It runs a scripted list of pkg/sftp client
// path and metadata operations against the private Unix/TLS fixture and prints each
// result in a normalized JSON form; it performs no local file operations.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path"
	"strconv"
	"strings"
	"syscall"
	"time"

	incus "github.com/lxc/incus/v7/client"
	"github.com/pkg/sftp"
)

type step struct {
	Op       string     `json:"op"`
	Path     string     `json:"path"`
	Path2    string     `json:"path2"`
	Elems    []string   `json:"elems"`
	Pattern  string     `json:"pattern"`
	Name     string     `json:"name"`
	Mode     uint32     `json:"mode"`
	UID      int        `json:"uid"`
	GID      int        `json:"gid"`
	Atime    int64      `json:"atime"`
	Mtime    int64      `json:"mtime"`
	Size     int64      `json:"size"`
	Extended [][]string `json:"extended"`
	Skip     []string   `json:"skip"`
}

func main() {
	var in struct {
		Socket, URL, CA, Cert, Key, Kind, Name, Pool, VolumeType, Project, Target string
		Steps                                                                     []step
	}
	if err := json.NewDecoder(os.Stdin).Decode(&in); err != nil {
		panic(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	args := &incus.ConnectionArgs{SkipGetEvents: true, TLSCA: in.CA, TLSClientCert: in.Cert, TLSClientKey: in.Key}
	var server incus.InstanceServer
	var err error
	if in.Socket != "" {
		server, err = incus.ConnectIncusUnixWithContext(ctx, in.Socket, args)
	} else {
		server, err = incus.ConnectIncusWithContext(ctx, in.URL, args)
	}
	if err != nil {
		panic(err)
	}
	defer server.Disconnect()
	if in.Project != "" {
		server = server.UseProject(in.Project)
	}
	if in.Target != "" {
		server = server.UseTarget(in.Target)
	}
	var client *sftp.Client
	if in.Kind == "volume" {
		client, err = server.GetStoragePoolVolumeFileSFTP(in.Pool, in.VolumeType, in.Name)
	} else {
		client, err = server.GetInstanceFileSFTP(in.Name)
	}
	if err != nil {
		_ = json.NewEncoder(os.Stdout).Encode(map[string]any{"error": failure(err)})
		return
	}
	results := []any{}
	for _, s := range in.Steps {
		results = append(results, run(client, s))
	}
	_ = client.Close()
	_ = json.NewEncoder(os.Stdout).Encode(map[string]any{"steps": results})
}

func run(c *sftp.Client, s step) map[string]any {
	var value any
	var err error
	switch s.Op {
	case "stat":
		value, err = info(c.Stat(s.Path))
	case "lstat":
		value, err = info(c.Lstat(s.Path))
	case "read_dir":
		var entries []os.FileInfo
		entries, err = c.ReadDir(s.Path)
		list := []any{}
		for _, entry := range entries {
			list = append(list, stat(entry))
		}
		value = list
	case "read_link":
		value, err = c.ReadLink(s.Path)
	case "real_path":
		value, err = c.RealPath(s.Path)
	case "getwd":
		value, err = c.Getwd()
	case "link":
		err = c.Link(s.Path, s.Path2)
	case "symlink":
		err = c.Symlink(s.Path, s.Path2)
	case "chmod":
		err = c.Chmod(s.Path, os.FileMode(s.Mode))
	case "chown":
		err = c.Chown(s.Path, s.UID, s.GID)
	case "chtimes":
		err = c.Chtimes(s.Path, time.Unix(s.Atime, 0), time.Unix(s.Mtime, 0))
	case "truncate":
		err = c.Truncate(s.Path, s.Size)
	case "set_extended_data":
		extended := []sftp.StatExtended{}
		for _, pair := range s.Extended {
			extended = append(extended, sftp.StatExtended{ExtType: pair[0], ExtData: pair[1]})
		}
		err = c.SetExtendedData(s.Path, extended)
	case "stat_vfs":
		var vfs *sftp.StatVFS
		vfs, err = c.StatVFS(s.Path)
		if err == nil {
			value = map[string]uint64{"bsize": vfs.Bsize, "frsize": vfs.Frsize, "blocks": vfs.Blocks,
				"bfree": vfs.Bfree, "bavail": vfs.Bavail, "files": vfs.Files, "ffree": vfs.Ffree,
				"favail": vfs.Favail, "fsid": vfs.Fsid, "flag": vfs.Flag, "namemax": vfs.Namemax}
		}
	case "remove":
		err = c.Remove(s.Path)
	case "remove_directory":
		err = c.RemoveDirectory(s.Path)
	case "rename":
		err = c.Rename(s.Path, s.Path2)
	case "posix_rename":
		err = c.PosixRename(s.Path, s.Path2)
	case "mkdir":
		err = c.Mkdir(s.Path)
	case "mkdir_all":
		err = c.MkdirAll(s.Path)
	case "remove_all":
		err = c.RemoveAll(s.Path)
	case "has_extension":
		data, found := c.HasExtension(s.Name)
		value = map[string]any{"found": found, "data": data}
	case "glob":
		var matches []string
		matches, err = c.Glob(s.Pattern)
		if matches == nil {
			matches = []string{}
		}
		value = matches
	case "walk":
		items := []any{}
		walker := c.Walk(s.Path)
		for walker.Step() {
			item := map[string]any{"path": walker.Path(), "stat": nil, "error": nil}
			if walker.Err() != nil {
				item["error"] = failure(walker.Err())
			} else {
				item["stat"] = stat(walker.Stat())
			}
			items = append(items, item)
			for _, skip := range s.Skip {
				if walker.Path() == skip {
					walker.SkipDir()
				}
			}
		}
		value = items
	case "join":
		value = sftp.Join(s.Elems...)
	case "split":
		dir, file := sftp.Split(s.Path)
		value = []string{dir, file}
	case "match":
		var matched bool
		matched, err = sftp.Match(s.Pattern, s.Name)
		value = matched
	default:
		panic("unknown step " + s.Op)
	}
	if err != nil {
		return map[string]any{"op": s.Op, "error": failure(err)}
	}
	return map[string]any{"op": s.Op, "ok": value}
}

func info(fi os.FileInfo, err error) (any, error) {
	if err != nil {
		return nil, err
	}
	return stat(fi), nil
}

func stat(fi os.FileInfo) map[string]any {
	fs := fi.Sys().(*sftp.FileStat)
	extended := [][]string{}
	for _, pair := range fs.Extended {
		extended = append(extended, []string{pair.ExtType, pair.ExtData})
	}
	return map[string]any{"name": fi.Name(), "size": fi.Size(), "mode": fs.Mode,
		"go_mode": uint32(fi.Mode()), "is_dir": fi.IsDir(), "mtime": fs.Mtime,
		"atime": fs.Atime, "uid": fs.UID, "gid": fs.GID, "extended": extended}
}

// failure normalizes a pinned client error: Go's error class, the native status
// code and message, and any os.PathError operation and path.
func failure(err error) map[string]any {
	result := map[string]any{}
	var pathErr *os.PathError
	if errors.As(err, &pathErr) {
		result["op"] = pathErr.Op
		result["path"] = pathErr.Path
	}
	var status *sftp.StatusError
	switch {
	case errors.As(err, &status):
		result["class"] = "status"
		result["code"] = status.Code
		text := status.Error()
		if start, end := strings.Index(text, `"`), strings.LastIndex(text, `"`); start >= 0 && end > start {
			if message, unquoteErr := strconv.Unquote(text[start : end+1]); unquoteErr == nil {
				result["message"] = message
			}
		}
	case errors.Is(err, os.ErrNotExist):
		result["class"] = "not_exist"
	case errors.Is(err, os.ErrPermission):
		result["class"] = "permission"
	case errors.Is(err, io.EOF):
		result["class"] = "eof"
	case errors.Is(err, syscall.ENOTDIR):
		result["class"] = "not_dir"
	case errors.Is(err, path.ErrBadPattern):
		result["class"] = "bad_pattern"
	default:
		result["class"] = "other"
		result["text"] = err.Error()
	}
	return result
}
