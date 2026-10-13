// Fixture-only unchanged shared/api response model oracle; stdin/stdout only.
package main

import (
	"encoding/json"
	"fmt"
	"math"
	"os"

	"github.com/lxc/incus/v7/shared/api"
)

func main() {
	var input struct {
		Cases []struct {
			Type string `json:"type"`
			JSON string `json:"json"`
		} `json:"cases"`
	}
	if err := json.NewDecoder(os.Stdin).Decode(&input); err != nil {
		panic(err)
	}
	results := make([]map[string]any, 0, len(input.Cases))
	for _, c := range input.Cases {
		var value any
		switch c.Type {
		case "Response":
			value = &api.Response{}
		case "ResponseRaw":
			value = &api.ResponseRaw{}
		case "ResponseType":
			value = new(api.ResponseType)
		default:
			panic("unknown response model")
		}
		if err := json.Unmarshal([]byte(c.JSON), value); err != nil {
			results = append(results, map[string]any{"accepted": false})
			continue
		}
		out, err := json.Marshal(value)
		if err != nil {
			panic(err)
		}
		result := map[string]any{"accepted": true, "canonical": string(out)}
		if raw, ok := value.(*api.ResponseRaw); ok {
			result["metadata_bits"] = floatBits(raw.Metadata)
		}
		results = append(results, result)
	}
	if err := json.NewEncoder(os.Stdout).Encode(map[string]any{"results": results}); err != nil {
		panic(err)
	}
}

// Compare the unchanged decoded float64 values independently of JSON spelling.
func floatBits(value any) any {
	switch v := value.(type) {
	case float64:
		return map[string]any{"float64": fmt.Sprintf("%016X", math.Float64bits(v))}
	case []any:
		out := make([]any, len(v))
		for i, item := range v {
			out[i] = floatBits(item)
		}
		return out
	case map[string]any:
		out := make(map[string]any, len(v))
		for key, item := range v {
			out[key] = floatBits(item)
		}
		return out
	default:
		return value
	}
}
