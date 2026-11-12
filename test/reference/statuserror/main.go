// Fixture-only unchanged StatusError oracle; no backend, network or files.
package main

import (
	"encoding/json"
	"errors"
	"os"

	"github.com/lxc/incus/v7/shared/api"
)

type testCase struct {
	Status  int64   `json:"status"`
	Message string  `json:"message"`
	Codes   []int64 `json:"codes"`
	Plain   bool    `json:"plain"`
	Zero    bool    `json:"zero"`
}

type result struct {
	Error  string `json:"error"`
	Status *int64 `json:"status"`
	Match  []any  `json:"match"`
	Check  bool   `json:"check"`
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
		var (
			err    error
			status *int64
		)
		switch {
		case c.Plain:
			err = errors.New("not a status error")
		case c.Zero:
			statusErr := api.StatusError{}
			err = statusErr
			value := int64(statusErr.Status())
			status = &value
		default:
			statusErr := api.StatusErrorf(int(c.Status), c.Message)
			err = statusErr
			value := int64(statusErr.Status())
			status = &value
		}

		codes := make([]int, 0, len(c.Codes))
		for _, code := range c.Codes {
			codes = append(codes, int(code))
		}

		matched, found := api.StatusErrorMatch(err, codes...)
		results = append(results, result{
			Error:  err.Error(),
			Status: status,
			Match:  []any{matched, found},
			Check:  api.StatusErrorCheck(err, codes...),
		})
	}

	if err := json.NewEncoder(os.Stdout).Encode(map[string]any{"results": results}); err != nil {
		panic(err)
	}
}
