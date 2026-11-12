// Fixture-only oracle for unchanged native ConfigMap/DevicesMap JSON decoders.
package main

import (
	"encoding/json"
	"github.com/lxc/incus/v7/shared/api"
	"os"
)

func main() {
	var input struct {
		Type     string          `json:"type"`
		Body     json.RawMessage `json:"body"`
		Existing json.RawMessage `json:"existing"`
	}
	if err := json.NewDecoder(os.Stdin).Decode(&input); err != nil {
		panic(err)
	}
	var target any
	switch input.Type {
	case "ConfigMap":
		var value api.ConfigMap
		target = &value
	case "DevicesMap":
		var value api.DevicesMap
		target = &value
	default:
		panic("unknown fixture type")
	}
	if len(input.Existing) > 0 {
		if err := json.Unmarshal(input.Existing, target); err != nil {
			panic(err)
		}
	}
	err := json.Unmarshal(input.Body, target)
	result := map[string]any{}
	if err != nil {
		result["error"] = true
	} else {
		result["value"] = target
	}
	if err := json.NewEncoder(os.Stdout).Encode(result); err != nil {
		panic(err)
	}
}
