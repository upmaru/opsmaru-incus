// Macus inventory generator. This uses only the Go standard library and is a
// development verifier, never an installed gateway or workload implementation.
package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"go/ast"
	"go/format"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

type Reference struct {
	Repository  string   `json:"repository"`
	Tag         string   `json:"tag"`
	Revision    string   `json:"revision"`
	Module      string   `json:"module"`
	Packages    []string `json:"packages"`
	License     string   `json:"license"`
	LicenseFile string   `json:"license_file"`
	Go          string   `json:"go"`
}

type Source struct {
	Path   string `json:"path"`
	SHA256 string `json:"sha256"`
}

type Entry struct {
	ID               string   `json:"id"`
	Kind             string   `json:"kind"`
	Package          string   `json:"package"`
	Name             string   `json:"name"`
	Source           string   `json:"source"`
	Line             int      `json:"line"`
	Signature        string   `json:"signature"`
	BuildConstraints []string `json:"build_constraints"`
	Elixir           *string  `json:"elixir"`
	Evidence         []string `json:"evidence"`
}

type Inventory struct {
	Schema    int       `json:"schema"`
	Reference Reference `json:"reference"`
	Sources   []Source  `json:"sources"`
	Entries   []Entry   `json:"entries"`
}

func fail(err error) {
	fmt.Fprintln(os.Stderr, err)
	os.Exit(1)
}

func signature(fset *token.FileSet, node any) string {
	var out bytes.Buffer
	if err := format.Node(&out, fset, node); err != nil {
		fail(err)
	}
	return out.String()
}

func receiver(expr ast.Expr) string {
	if pointer, ok := expr.(*ast.StarExpr); ok {
		return receiver(pointer.X)
	}
	if name, ok := expr.(*ast.Ident); ok {
		return name.Name
	}
	if generic, ok := expr.(*ast.IndexExpr); ok {
		return receiver(generic.X)
	}
	if generic, ok := expr.(*ast.IndexListExpr); ok {
		return receiver(generic.X)
	}
	fail(fmt.Errorf("unsupported method receiver %T", expr))
	return ""
}

func main() {
	if len(os.Args) != 3 {
		fail(fmt.Errorf("usage: incus-inventory SOURCE_ROOT REFERENCE_JSON"))
	}
	var ref Reference
	refBytes, err := os.ReadFile(os.Args[2])
	if err != nil {
		fail(err)
	}
	if err := json.Unmarshal(refBytes, &ref); err != nil {
		fail(err)
	}
	inv := Inventory{Schema: 1, Reference: ref, Sources: []Source{}, Entries: []Entry{}}
	fset := token.NewFileSet()
	for _, pkg := range ref.Packages {
		files, err := filepath.Glob(filepath.Join(os.Args[1], pkg, "*.go"))
		if err != nil {
			fail(err)
		}
		if len(files) == 0 {
			fail(fmt.Errorf("no sources in %s", pkg))
		}
		for _, file := range files {
			if strings.HasSuffix(file, "_test.go") {
				continue
			}
			data, err := os.ReadFile(file)
			if err != nil {
				fail(err)
			}
			digest := sha256.Sum256(data)
			path := filepath.ToSlash(filepath.Join(pkg, filepath.Base(file)))
			inv.Sources = append(inv.Sources, Source{path, hex.EncodeToString(digest[:])})
			parsed, err := parser.ParseFile(fset, file, data, parser.ParseComments)
			if err != nil {
				fail(err)
			}
			constraints := []string{}
			for _, group := range parsed.Comments {
				for _, c := range group.List {
					if strings.HasPrefix(c.Text, "//go:build ") || strings.HasPrefix(c.Text, "// +build ") {
						constraints = append(constraints, c.Text)
					}
				}
			}
			add := func(kind, name, sig string, pos token.Pos) {
				inv.Entries = append(inv.Entries, Entry{
					ID: pkg + "/" + kind + "/" + name, Kind: kind, Package: pkg, Name: name,
					Source: path, Line: fset.Position(pos).Line, Signature: sig,
					BuildConstraints: constraints, Elixir: nil, Evidence: []string{},
				})
			}
			for _, decl := range parsed.Decls {
				switch d := decl.(type) {
				case *ast.FuncDecl:
					if !d.Name.IsExported() {
						continue
					}
					name, kind := d.Name.Name, "function"
					if d.Recv != nil {
						name = receiver(d.Recv.List[0].Type) + "." + name
						kind = "method"
					}
					// Strip implementation and comments while retaining the full signature.
					copy := *d
					copy.Body = nil
					copy.Doc = nil
					add(kind, name, signature(fset, &copy), d.Pos())
				case *ast.GenDecl:
					for _, spec := range d.Specs {
						switch s := spec.(type) {
						case *ast.TypeSpec:
							if !s.Name.IsExported() {
								continue
							}
							copy := *s
							copy.Doc = nil
							copy.Comment = nil
							add("type", s.Name.Name, signature(fset, &copy), s.Pos())
							if iface, ok := s.Type.(*ast.InterfaceType); ok {
								for _, field := range iface.Methods.List {
									for _, name := range field.Names {
										if name.IsExported() {
											add("interface_method", s.Name.Name+"."+name.Name,
												name.Name+signature(fset, field.Type), field.Pos())
										}
									}
								}
							}
						case *ast.ValueSpec:
							// Include exported constants/variables as compatibility inputs.
							for _, name := range s.Names {
								if name.IsExported() {
									add(d.Tok.String(), name.Name, signature(fset, s), s.Pos())
								}
							}
						}
					}
				}
			}
		}
	}
	sort.Slice(inv.Sources, func(i, j int) bool { return inv.Sources[i].Path < inv.Sources[j].Path })
	sort.Slice(inv.Entries, func(i, j int) bool {
		if inv.Entries[i].ID != inv.Entries[j].ID {
			return inv.Entries[i].ID < inv.Entries[j].ID
		}
		return inv.Entries[i].Source < inv.Entries[j].Source
	})
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	if err := enc.Encode(inv); err != nil {
		fail(err)
	}
}
