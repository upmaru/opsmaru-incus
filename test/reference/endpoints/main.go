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
		Paths map[string]map[string]any `yaml:"paths"`
	}
	if err := yaml.Unmarshal(data, &spec); err != nil {
		return err
	}
	pairs := []string{}
	for path, actions := range spec.Paths {
		for verb := range actions {
			switch verb {
			case "get", "post", "put", "patch", "delete", "head", "options":
				pairs = append(pairs, strings.ToUpper(verb)+" "+path)
			}
		}
	}
	sort.Strings(pairs)
	digest := sha256.Sum256(data)
	return json.NewEncoder(os.Stdout).Encode(map[string]any{
		"source": "doc/rest-api.yaml", "sha256": hex.EncodeToString(digest[:]), "pairs": pairs,
	})
}
