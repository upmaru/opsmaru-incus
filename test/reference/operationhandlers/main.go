// Pinned operation AddHandler/RemoveHandler oracle against an isolated echo fixture.
package main

import (
	"context"
	"encoding/json"
	"os"
	"time"

	incus "github.com/lxc/incus/v7/client"
	"github.com/lxc/incus/v7/shared/api"
)

func main() {
	var input struct {
		Socket string      `json:"socket"`
		Events []api.Event `json:"events"`
		Expect int         `json:"expect"`
	}
	if err := json.NewDecoder(os.Stdin).Decode(&input); err != nil {
		panic(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	client, err := incus.ConnectIncusUnixWithContext(ctx, input.Socket, &incus.ConnectionArgs{SkipGetEvents: true})
	if err != nil {
		panic(err)
	}
	// An explicit listener clears SkipGetEvents and opens the shared events connection.
	base, err := client.GetEvents()
	if err != nil {
		panic(err)
	}
	defer base.Disconnect()

	op, err := client.DeleteInstance("c1")
	if err != nil {
		panic(err)
	}

	out := map[string]any{}
	seen := make(chan api.Operation, 16)
	target, err := op.AddHandler(func(o api.Operation) { seen <- o })
	out["add_error"] = errString(err)
	out["target_nil"] = target == nil

	if target != nil {
		removed, err := op.AddHandler(func(o api.Operation) { seen <- api.Operation{ID: "removed"} })
		if err != nil {
			panic(err)
		}
		out["remove"] = errString(op.RemoveHandler(removed))
		out["remove_again"] = errString(op.RemoveHandler(removed))
		out["remove_nil"] = errString(op.RemoveHandler(nil))

		for _, event := range input.Events {
			if err := client.SendEvent(event); err != nil {
				panic(err)
			}
		}

		ops := []api.Operation{}
		timer := time.NewTimer(1500 * time.Millisecond)
	collect:
		for len(ops) < input.Expect {
			select {
			case o := <-seen:
				ops = append(ops, o)
			case <-timer.C:
				break collect
			}
		}
		// Allow any unexpected extra callbacks to surface.
		select {
		case o := <-seen:
			ops = append(ops, o)
		case <-time.After(200 * time.Millisecond):
		}
		out["seen"] = ops
	}

	if err := json.NewEncoder(os.Stdout).Encode(out); err != nil {
		panic(err)
	}
}

func errString(err error) any {
	if err == nil {
		return nil
	}
	return err.Error()
}
