// Fixture-only unchanged ParseFileHeaders oracle; no backend or filesystem state.
package main

import (
	"encoding/json"
	"net/http"
	"os"

	"github.com/lxc/incus/v7/shared/api"
)

func main() {
	var input struct {
		Headers [][2]string `json:"headers"`
	}
	if err := json.NewDecoder(os.Stdin).Decode(&input); err != nil {
		panic(err)
	}
	headers := http.Header{}
	for _, pair := range input.Headers {
		headers.Add(pair[0], pair[1])
	}
	uid, gid, mode, kind, write := api.ParseFileHeaders(headers)
	if err := json.NewEncoder(os.Stdout).Encode(map[string]any{
		"uid": uid, "gid": gid, "mode": mode, "type": kind, "write_mode": write,
	}); err != nil {
		panic(err)
	}
}
