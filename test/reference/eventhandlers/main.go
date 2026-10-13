// Pinned event listener lifecycle oracle against an isolated echo fixture.
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
		Socket string    `json:"socket"`
		Event  api.Event `json:"event"`
	}
	if err := json.NewDecoder(os.Stdin).Decode(&input); err != nil {
		panic(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	client, err := incus.ConnectIncusUnixWithContext(ctx, input.Socket, &incus.ConnectionArgs{SkipGetEvents: true})
	if err != nil {
		panic(err)
	}
	listener, err := client.GetEvents()
	if err != nil {
		panic(err)
	}
	defer listener.Disconnect()
	seen := make(chan api.Event, 1)
	_, err = listener.AddHandler([]string{"logging"}, func(e api.Event) { seen <- e })
	if err != nil {
		panic(err)
	}
	target, err := listener.AddHandler(nil, func(e api.Event) {})
	if err != nil {
		panic(err)
	}
	out := map[string]any{"active_before": listener.IsActive(), "remove": listener.RemoveHandler(target) == nil}
	out["remove_again"] = listener.RemoveHandler(target) == nil
	_, err = listener.AddHandler(nil, nil)
	out["invalid_handler"] = err != nil
	if err := client.SendEvent(input.Event); err != nil {
		panic(err)
	}
	select {
	case event := <-seen:
		out["event"] = event
	case <-ctx.Done():
		panic("callback deadline")
	}
	listener.Disconnect()
	out["active_after"] = listener.IsActive()
	out["wait"] = listener.Wait() == nil
	out["wait_again"] = listener.Wait() == nil
	if err := json.NewEncoder(os.Stdout).Encode(out); err != nil {
		panic(err)
	}
}
