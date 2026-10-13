// Fixture-only oracle. Calls the unmodified pinned Incus SimpleStreams client
// against an explicitly supplied private TLS fixture; never downloads images,
// probes /dev/incus/sock, runs xdelta, or contacts a public registry.
package main

import (
	"encoding/json"
	incus "github.com/lxc/incus/v7/client"
	"github.com/lxc/incus/v7/shared/api"
	"github.com/lxc/incus/v7/shared/osarch"
	"github.com/lxc/incus/v7/shared/simplestreams"
	"os"
	"sort"
)

func main() {
	var in struct {
		URL, Certificate    string
		Names, Fingerprints []string
	}
	if err := json.NewDecoder(os.Stdin).Decode(&in); err != nil {
		panic(err)
	}
	client, err := incus.ConnectSimpleStreams(in.URL, &incus.ConnectionArgs{TLSServerCert: in.Certificate})
	if err != nil {
		panic(err)
	}
	defer client.Disconnect()
	arch, _ := osarch.ArchitectureGetLocal()
	images, err := client.GetImages()
	if err != nil {
		panic(err)
	}
	all, err := client.GetImagesAllProjects()
	if err != nil {
		panic(err)
	}
	fingerprints, err := client.GetImageFingerprints()
	if err != nil {
		panic(err)
	}
	aliases, err := client.GetImageAliases()
	if err != nil {
		panic(err)
	}
	sort.Slice(aliases, func(i, j int) bool { return aliases[i].Name+aliases[i].Type < aliases[j].Name+aliases[j].Type })
	aliasNames, err := client.GetImageAliasNames()
	if err != nil {
		panic(err)
	}
	sort.Strings(aliasNames)
	out := map[string]any{"architecture": arch, "images": images, "all": all, "fingerprints": fingerprints, "aliases": aliases, "alias_names": aliasNames}
	selected := map[string]any{}
	for _, name := range in.Names {
		for _, kind := range []string{"", "container", "virtual-machine"} {
			alias, _, err := client.GetImageAliasType(kind, name)
			architectures, architectureErr := client.GetImageAliasArchitectures(kind, name)
			value := map[string]any{"alias": alias, "architectures": architectures}
			if err != nil {
				value["error"] = err.Error()
			}
			if architectureErr != nil {
				value["architecture_error"] = architectureErr.Error()
			}
			selected[name+":"+kind] = value
		}
	}
	out["selected"] = selected
	imageResults := map[string]any{}
	for _, hash := range in.Fingerprints {
		image, etag, err := client.GetImage(hash)
		value := map[string]any{"image": image, "etag": etag}
		if err != nil {
			value["error"] = err.Error()
		}
		imageResults[hash] = value
	}
	out["image_results"] = imageResults
	httpClient, err := client.GetHTTPClient()
	if err != nil {
		panic(err)
	}
	stream := simplestreams.NewClient(in.URL, *httpClient, "")
	files := map[string]any{}
	for _, image := range images {
		value, err := stream.GetFiles(image.Fingerprint)
		if err != nil {
			panic(err)
		}
		files[image.Fingerprint] = value
	}
	out["files"] = files
	errors := map[string]string{}
	_, err = client.GetImagesWithFilter(nil)
	errors["GetImagesWithFilter"] = err.Error()
	_, err = client.GetImagesAllProjectsWithFilter(nil)
	errors["GetImagesAllProjectsWithFilter"] = err.Error()
	_, err = client.GetImageSecret("")
	errors["GetImageSecret"] = err.Error()
	_, _, err = client.GetPrivateImage("", "")
	errors["GetPrivateImage"] = err.Error()
	_, err = client.GetPrivateImageFile("", "", incus.ImageFileRequest{})
	errors["GetPrivateImageFile"] = err.Error()
	_, err = client.ExportImage("", api.ImageExportPost{})
	errors["ExportImage"] = err.Error()
	out["unsupported"] = errors
	client.Disconnect()
	out["disconnect"] = "ok"
	if err := json.NewEncoder(os.Stdout).Encode(out); err != nil {
		panic(err)
	}
}
