// Fixture-only oracle: the declared fields of the unchanged pinned client
// argument structs, read by reflection. No backend, network or filesystem state.
package main

import (
	"encoding/json"
	"os"
	"reflect"

	incus "github.com/lxc/incus/v7/client"
)

type field struct {
	Name string `json:"name"`
	Type string `json:"type"`
}

type shape struct {
	Fields   []field  `json:"fields"`
	Embedded []string `json:"embedded"`
}

func main() {
	structs := map[string]any{
		"ImageCopyArgs":             incus.ImageCopyArgs{},
		"InstanceCopyArgs":          incus.InstanceCopyArgs{},
		"InstanceSnapshotCopyArgs":  incus.InstanceSnapshotCopyArgs{},
		"StoragePoolVolumeCopyArgs": incus.StoragePoolVolumeCopyArgs{},
		"StoragePoolVolumeMoveArgs": incus.StoragePoolVolumeMoveArgs{},
	}
	out := map[string]shape{}
	for name, value := range structs {
		s := shape{Fields: []field{}, Embedded: []string{}}
		// Anonymous members are followed immediately by their promoted fields.
		for _, f := range reflect.VisibleFields(reflect.TypeOf(value)) {
			if f.Anonymous {
				s.Embedded = append(s.Embedded, f.Name)
				continue
			}
			s.Fields = append(s.Fields, field{Name: f.Name, Type: f.Type.String()})
		}
		out[name] = s
	}
	if err := json.NewEncoder(os.Stdout).Encode(out); err != nil {
		panic(err)
	}
}
