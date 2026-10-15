// Development-only extraction from the unchanged pinned REST specification.
package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"go.yaml.in/yaml/v4"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run() error {
	if len(os.Args) != 2 {
		return fmt.Errorf("usage: endpoints INCUS_MODULE_ROOT")
	}
	data, err := os.ReadFile(filepath.Join(os.Args[1], "doc/rest-api.yaml"))
	if err != nil {
		return err
	}
	var spec struct {
		Paths map[string]map[string]yaml.Node `yaml:"paths"`
	}
	if err := yaml.Unmarshal(data, &spec); err != nil {
		return err
	}
	pairs := []string{}
	queries := map[string][]string{}
	for path, actions := range spec.Paths {
		for verb, node := range actions {
			switch verb {
			case "get", "post", "put", "patch", "delete", "head", "options":
				key := strings.ToUpper(verb) + " " + path
				pairs = append(pairs, key)
				var action struct{ Parameters []struct{ In, Name string } }
				if err := node.Decode(&action); err != nil {
					return err
				}
				queries[key] = []string{}
				for _, parameter := range action.Parameters {
					if parameter.In == "query" {
						queries[key] = append(queries[key], parameter.Name)
					}
				}
				sort.Strings(queries[key])
			}
		}
	}
	sort.Strings(pairs)
	routes, hashes, err := serverRoutes(os.Args[1])
	if err != nil {
		return err
	}
	digest := sha256.Sum256(data)
	return json.NewEncoder(os.Stdout).Encode(map[string]any{
		"source": "doc/rest-api.yaml", "sha256": hex.EncodeToString(digest[:]), "pairs": pairs,
		"server_routes": routes, "server_sources": hashes, "query_parameters": queries,
	})
}
