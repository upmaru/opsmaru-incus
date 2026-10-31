// Fixture-only unchanged OCI helper oracle. The PATH stub emits supplied
// inspection JSON; it never contacts a registry or runs conversion/root tools.
package main

import (
	"encoding/json"
	incus "github.com/lxc/incus/v7/client"
	"github.com/lxc/incus/v7/shared/api"
	"github.com/lxc/incus/v7/shared/osarch"
	"os"
	"path/filepath"
)

func main() {
	var in struct {
		Action string
		Name   string
		Type   string
		Info   json.RawMessage
	}
	if err := json.NewDecoder(os.Stdin).Decode(&in); err != nil {
		panic(err)
	}
	dir, err := os.MkdirTemp("", "opsmaru-oci-oracle-")
	if err != nil {
		panic(err)
	}
	defer os.RemoveAll(dir)
	if err := os.WriteFile(filepath.Join(dir, "info.json"), in.Info, 0600); err != nil {
		panic(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "skopeo"), []byte("#!/bin/sh\nexec /bin/cat \"$OPSMARU_OCI_FIXTURE\"\n"), 0700); err != nil {
		panic(err)
	}
	os.Setenv("PATH", dir)
	os.Setenv("OPSMARU_OCI_FIXTURE", filepath.Join(dir, "info.json"))
	client, err := incus.ConnectOCI("https://fixture.invalid", nil)
	if err != nil {
		panic(err)
	}
	defer client.Disconnect()
	var value any
	switch in.Action {
	case "resolve":
		alias, _, e := client.GetImageAliasType(in.Type, in.Name)
		err = e
		if err == nil {
			image, _, e := client.GetImage(alias.Target)
			err = e
			value = map[string]any{"alias": alias, "image": image}
		}
	case "metadata":
		// The pinned GetImageFile marshals these values, read through the unchanged
		// cache, as metadata.yaml; the conversion itself needs root, skopeo and umoci.
		alias, _, e := client.GetImageAliasType(in.Type, in.Name)
		err = e
		if err == nil {
			image, _, e := client.GetImage(alias.Target)
			err = e
			if err == nil {
				data, e := json.Marshal(api.ImageMetadata{Architecture: image.Architecture, CreationDate: image.CreatedAt.Unix()})
				err = e
				value = string(data)
			}
		}
	case "failed-lookup":
		// The pinned client keeps a failed lookup's error for a later GetImage by name.
		if _, _, e := client.GetImageAlias(in.Name); e == nil {
			panic("lookup unexpectedly succeeded")
		}
		value, _, err = client.GetImage(in.Name)
	case "GetImageFile":
		// Cache-miss and empty-request order; a hit with no files fails before root.
		target := in.Name
		if in.Type != "miss" {
			alias, _, e := client.GetImageAlias(in.Name)
			if e != nil {
				panic(e)
			}
			target = alias.Target
		}
		value, err = client.GetImageFile(target, incus.ImageFileRequest{})
	case "GetImageAliasArchitectures":
		value, err = client.GetImageAliasArchitectures(in.Type, in.Name)
	case "Disconnect":
		client.Disconnect()
		value = "ok"
	case "GetImages":
		value, err = client.GetImages()
	case "GetImagesAllProjects":
		value, err = client.GetImagesAllProjects()
	case "GetImagesAllProjectsWithFilter":
		value, err = client.GetImagesAllProjectsWithFilter(nil)
	case "GetImagesWithFilter":
		value, err = client.GetImagesWithFilter(nil)
	case "GetImageFingerprints":
		value, err = client.GetImageFingerprints()
	case "GetImageAliases":
		value, err = client.GetImageAliases()
	case "GetImageAliasNames":
		value, err = client.GetImageAliasNames()
	case "GetImageSecret":
		value, err = client.GetImageSecret(in.Name)
	case "GetPrivateImage":
		value, _, err = client.GetPrivateImage(in.Name, "private")
	case "GetPrivateImageFile":
		value, err = client.GetPrivateImageFile(in.Name, "private", incus.ImageFileRequest{})
	case "ExportImage":
		value, err = client.ExportImage(in.Name, api.ImageExportPost{})
	default:
		panic("unknown action")
	}
	out := map[string]any{"ok": err == nil, "value": value}
	localArch, archErr := osarch.ArchitectureGetLocal()
	if archErr != nil {
		panic(archErr)
	}
	out["local_architecture"] = localArch
	if err != nil {
		out["error"] = err.Error()
	}
	if err := json.NewEncoder(os.Stdout).Encode(out); err != nil {
		panic(err)
	}
}
