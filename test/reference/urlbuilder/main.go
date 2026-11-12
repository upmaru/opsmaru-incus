// Fixture-only calls to unchanged Incus v7.0.1 API URL exports.
package main

import (
	"encoding/json"
	"github.com/lxc/incus/v7/shared/api"
	"os"
)

func main() {
	var input struct {
		Steps []struct {
			Action string
			Values []string
		}
	}
	if err := json.NewDecoder(os.Stdin).Decode(&input); err != nil {
		panic(err)
	}
	u := api.NewURL()
	results := []string{u.String()}
	for _, s := range input.Steps {
		switch s.Action {
		case "scheme":
			u.Scheme(s.Values[0])
		case "host":
			u.Host(s.Values[0])
		case "path":
			u.Path(s.Values...)
		case "project":
			u.Project(s.Values[0])
		case "target":
			u.Target(s.Values[0])
		case "query":
			u.WithQuery(s.Values[0], s.Values[1])
		case "fragment":
			u.Fragment(s.Values[0])
		default:
			panic("unknown fixture action")
		}
		results = append(results, u.String())
	}
	if err := json.NewEncoder(os.Stdout).Encode(results); err != nil {
		panic(err)
	}
}
