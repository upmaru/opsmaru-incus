// Fixture-only unchanged configuration metadata helper; no backend.
package main

import (
	"encoding/json"
	"github.com/lxc/incus/v7/shared/api"
	"os"
)

func main() {
	var input struct {
		Body   json.RawMessage `json:"body"`
		Entity string          `json:"entity"`
		Group  string          `json:"group"`
	}
	if err := json.NewDecoder(os.Stdin).Decode(&input); err != nil {
		panic(err)
	}
	var config api.MetadataConfiguration
	err := json.Unmarshal(input.Body, &config)
	var value map[string]api.MetadataConfigKey
	if err == nil {
		value, err = config.GetKeys(input.Entity, input.Group)
	}
	out := map[string]any{"ok": err == nil}
	if err != nil {
		out["error"] = err.Error()
	} else {
		out["value"] = value
	}
	if err := json.NewEncoder(os.Stdout).Encode(out); err != nil {
		panic(err)
	}
}
