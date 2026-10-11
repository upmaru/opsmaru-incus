// Pure pinned native metadata/token helper oracle. No backend or credentials.
package main

import (
	"encoding/json"
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
	response := api.Response{Metadata: input.Body}
	switch input.Action {
	case "map":
		value, err = response.MetadataAsMap()
	case "strings":
		value, err = response.MetadataAsStringSlice()
	case "operation":
		value, err = response.MetadataAsOperation()
	case "instance":
		instance := api.Instance{}
		err = response.MetadataAsStruct(&instance)
		value = instance
	case "certificate", "cluster":
		operation := api.Operation{}
		err = json.Unmarshal(input.Body, &operation)
		if err == nil {
			if input.Action == "certificate" {
				var token *api.CertificateAddToken
				token, err = operation.ToCertificateAddToken()
				if err == nil {
					value = map[string]any{"token": token, "encoded": token.String()}
				}
			} else {
				var token *api.ClusterMemberJoinToken
				token, err = operation.ToClusterJoinToken()
				if err == nil {
					value = map[string]any{"token": token, "encoded": token.String()}
				}
			}
		}
	default:
		panic("unknown helper")
	}
	out := map[string]any{"ok": err == nil}
	if err == nil {
		out["value"] = value
	}
	if err := json.NewEncoder(os.Stdout).Encode(out); err != nil {
		panic(err)
	}
}
