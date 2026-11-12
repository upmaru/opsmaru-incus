// Fixture-only unchanged native network Normalise oracle; no backend access.
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"reflect"

	"github.com/lxc/incus/v7/shared/api"
)

func main() {
	var input struct {
		Type string          `json:"type"`
		Body json.RawMessage `json:"body"`
	}
	if err := json.NewDecoder(os.Stdin).Decode(&input); err != nil {
		panic(err)
	}
	models := map[string]any{
		"NetworkACLRule":             &api.NetworkACLRule{},
		"NetworkAddressSet":          &api.NetworkAddressSet{},
		"NetworkForwardPort":         &api.NetworkForwardPort{},
		"NetworkForwardPut":          &api.NetworkForwardPut{},
		"NetworkForwardsPost":        &api.NetworkForwardsPost{},
		"NetworkLoadBalancerBackend": &api.NetworkLoadBalancerBackend{},
		"NetworkLoadBalancerPort":    &api.NetworkLoadBalancerPort{},
		"NetworkLoadBalancerPut":     &api.NetworkLoadBalancerPut{},
	}
	model, ok := models[input.Type]
	if !ok {
		panic(fmt.Errorf("unsupported model %s", input.Type))
	}
	if err := json.Unmarshal(input.Body, model); err != nil {
		panic(err)
	}
	reflect.ValueOf(model).MethodByName("Normalise").Call(nil)
	if err := json.NewEncoder(os.Stdout).Encode(model); err != nil {
		panic(err)
	}
}
