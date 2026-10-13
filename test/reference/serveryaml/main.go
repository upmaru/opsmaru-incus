// Fixture-only unchanged ServerFiltered YAML oracle; no backend, network or files.
package main

import (
	"encoding/json"
	"os"

	"github.com/lxc/incus/v7/shared/api"
	yaml "go.yaml.in/yaml/v4"
)

type result struct {
	Accepted bool    `json:"accepted"`
	YAML     *string `json:"yaml"`
	Error    string  `json:"error,omitempty"`
}

func main() {
	var input struct {
		Cases []json.RawMessage `json:"cases"`
	}
	if err := json.NewDecoder(os.Stdin).Decode(&input); err != nil {
		panic(err)
	}

	results := make([]result, 0, len(input.Cases))
	for _, raw := range input.Cases {
		var server api.Server
		if err := json.Unmarshal(raw, &server); err != nil {
			results = append(results, result{Error: err.Error()})
			continue
		}

		out, err := yaml.Marshal(server.Filtered())
		if err != nil {
			results = append(results, result{Error: err.Error()})
			continue
		}

		text := string(out)
		results = append(results, result{Accepted: true, YAML: &text})
	}

	if err := json.NewEncoder(os.Stdout).Encode(map[string]any{"results": results}); err != nil {
		panic(err)
	}
}
