package main

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

func TestExportedDeclarationsAndSourceChanges(t *testing.T) {
	root := t.TempDir()
	if err := os.Mkdir(filepath.Join(root, "client"), 0700); err != nil {
		t.Fatal(err)
	}
	ref := filepath.Join(root, "reference.json")
	if err := os.WriteFile(ref, []byte(`{"packages":["client"]}`), 0600); err != nil {
		t.Fatal(err)
	}
	file := filepath.Join(root, "client", "api.go")
	data := `//go:build darwin
package client
type Parent interface { Existing() error }
type Child interface { Parent; Added(string) (int, error) }
type Model struct { Name string ` + "`json:\"name\"`" + ` }
type Alias = Model
func Exported() error { return nil }
func hidden() {}
func (m *Model) Read() string { return m.Name }
`
	if err := os.WriteFile(file, []byte(data), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "client", "api_test.go"), []byte("package client\nfunc TestOnly() {}"), 0600); err != nil {
		t.Fatal(err)
	}
	run := func() Inventory {
		cmd := exec.Command("go", "run", "incus-inventory.go", root, ref)
		out, err := cmd.Output()
		if err != nil {
			t.Fatal(err)
		}
		var inv Inventory
		if err := json.Unmarshal(out, &inv); err != nil {
			t.Fatal(err)
		}
		return inv
	}
	before := run()
	if len(before.Sources) != 1 || len(before.Entries) != 8 {
		t.Fatalf("missing or extra declarations: %+v", before)
	}
	for _, entry := range before.Entries {
		if len(entry.BuildConstraints) != 1 || entry.Line < 1 {
			t.Fatalf("missing source identity: %+v", entry)
		}
	}
	if err := os.WriteFile(file, []byte(data+"\nfunc NewPublicOperation() {}\n"), 0600); err != nil {
		t.Fatal(err)
	}
	after := run()
	if len(after.Entries) != 9 || before.Sources[0].SHA256 == after.Sources[0].SHA256 {
		t.Fatal("added public entry was not detected")
	}
}
