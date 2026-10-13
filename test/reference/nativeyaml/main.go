// Fixture-only unchanged ConfigMap/DevicesMap YAML oracle; no backend, network or files.
package main

import (
	"encoding/json"
	"fmt"
	"os"

	"github.com/lxc/incus/v7/shared/api"
	yaml "go.yaml.in/yaml/v4"
)

type testCase struct {
	Type     string          `json:"type"`
	YAML     string          `json:"yaml"`
	Existing *map[string]any `json:"existing"`
}

type result struct {
	Accepted bool            `json:"accepted"`
	Value    json.RawMessage `json:"value"`
	Error    string          `json:"error"`
}

func main() {
	var input struct {
		Cases []testCase `json:"cases"`
	}
	if err := json.NewDecoder(os.Stdin).Decode(&input); err != nil {
		panic(err)
	}

	results := make([]result, 0, len(input.Cases))
	for _, c := range input.Cases {
		results = append(results, run(c))
	}

	if err := json.NewEncoder(os.Stdout).Encode(map[string]any{"results": results}); err != nil {
		panic(err)
	}
}

func run(c testCase) result {
	var target any
	var err error

	switch c.Type {
	case "ConfigMap":
		cm := api.ConfigMap(nil)
		if c.Existing != nil {
			cm = api.ConfigMap{}
			for k, v := range *c.Existing {
				str, ok := v.(string)
				if !ok {
					fmt.Fprintln(os.Stderr, "existing ConfigMap value must be a string")
					os.Exit(1)
				}
				cm[k] = str
			}
		}

		err = yaml.Unmarshal([]byte(c.YAML), &cm)
		target = cm

	case "DevicesMap":
		dm := api.DevicesMap(nil)
		if c.Existing != nil {
			dm = api.DevicesMap{}
			for k, v := range *c.Existing {
				inner, ok := v.(map[string]any)
				if !ok {
					fmt.Fprintln(os.Stderr, "existing DevicesMap value must be a map")
					os.Exit(1)
				}
				props := map[string]string{}
				for pk, pv := range inner {
					str, ok := pv.(string)
					if !ok {
						fmt.Fprintln(os.Stderr, "existing DevicesMap property must be a string")
						os.Exit(1)
					}
					props[pk] = str
				}
				dm[k] = props
			}
		}

		err = yaml.Unmarshal([]byte(c.YAML), &dm)
		target = dm

	default:
		fmt.Fprintln(os.Stderr, "unknown model type:", c.Type)
		os.Exit(1)
	}

	out, merr := json.Marshal(target)
	if merr != nil {
		fmt.Fprintln(os.Stderr, "canonical marshal failed:", merr)
		os.Exit(1)
	}

	res := result{Accepted: err == nil, Value: out}
	if err != nil {
		res.Error = err.Error()
	}
	return res
}
