// Fixture-only unchanged native server filtering and event log projection.
package main

import (
	"encoding/json"
	"fmt"
	"os"

	"github.com/lxc/incus/v7/shared/api"
)

func main() {
	var input struct {
		Action string          `json:"action"`
		Body   json.RawMessage `json:"body"`
	}
	if err := json.NewDecoder(os.Stdin).Decode(&input); err != nil {
		panic(err)
	}
	var value any
	var err error
	switch input.Action {
	case "filtered":
		var server api.Server
		err = json.Unmarshal(input.Body, &server)
		if err == nil {
			value = server.Filtered()
		}
	case "logging":
		var event api.Event
		err = json.Unmarshal(input.Body, &event)
		if err == nil {
			value, err = event.ToLogging()
		}
	default:
		err = fmt.Errorf("unknown fixture action")
	}
	result := map[string]any{"ok": err == nil}
	if err != nil {
		result["error"] = err.Error()
	} else {
		result["value"] = value
	}
	if err := json.NewEncoder(os.Stdout).Encode(result); err != nil {
		panic(err)
	}
}
