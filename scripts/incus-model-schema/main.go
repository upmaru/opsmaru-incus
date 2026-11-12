// Verification/code-generation input only. No Go runtime dependency.
// JSON field schema derived from the immutable official shared/api source.
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
	"reflect"
	"strconv"
	"strings"
)

type field struct {
	Name string `json:"name"`
	Type string `json:"type"`
}
type model struct {
	Kind       string  `json:"kind"`
	Fields     []field `json:"fields"`
	Underlying string  `json:"underlying"`
}

func main() {
	if len(os.Args) != 3 {
		panic("usage: incus-model-schema SOURCE INVENTORY")
	}
	invBytes, err := os.ReadFile(os.Args[2])
	if err != nil {
		panic(err)
	}
	var inv struct {
		Reference struct {
			Revision string `json:"revision"`
		} `json:"reference"`
		Sources []struct {
			Path   string `json:"path"`
			SHA256 string `json:"sha256"`
		} `json:"sources"`
	}
	if err = json.Unmarshal(invBytes, &inv); err != nil {
		panic(err)
	}
	types := map[string]ast.Expr{}
	fset := token.NewFileSet()
	for _, src := range inv.Sources {
		data, err := os.ReadFile(filepath.Join(os.Args[1], src.Path))
		if err != nil {
			panic(err)
		}
		digest := sha256.Sum256(data)
		if hex.EncodeToString(digest[:]) != src.SHA256 {
			panic("source hash mismatch")
		}
		if !strings.HasPrefix(src.Path, "shared/api/") {
			continue
		}
		file, err := parser.ParseFile(fset, src.Path, data, 0)
		if err != nil {
			panic(err)
		}
		for _, decl := range file.Decls {
			if gen, ok := decl.(*ast.GenDecl); ok {
				for _, spec := range gen.Specs {
					if typ, ok := spec.(*ast.TypeSpec); ok && typ.Name.IsExported() {
						types[typ.Name.Name] = typ.Type
					}
				}
			}
		}
	}
	signature := func(expr ast.Expr) string {
		var b bytes.Buffer
		if err := format.Node(&b, fset, expr); err != nil {
			panic(err)
		}
		return b.String()
	}
	var fields func(ast.Expr, map[string]bool) []field
	fields = func(expr ast.Expr, seen map[string]bool) []field {
		if ptr, ok := expr.(*ast.StarExpr); ok {
			expr = ptr.X
		}
		if id, ok := expr.(*ast.Ident); ok {
			if seen[id.Name] {
				panic("cyclic embedded type")
			}
			seen[id.Name] = true
			defer delete(seen, id.Name)
			return fields(types[id.Name], seen)
		}
		st, ok := expr.(*ast.StructType)
		if !ok {
			return []field{}
		}
		result := []field{}
		for _, f := range st.Fields.List {
			if len(f.Names) == 0 {
				result = append(result, fields(f.Type, seen)...)
				continue
			}
			tag := ""
			if f.Tag != nil {
				value, err := strconv.Unquote(f.Tag.Value)
				if err != nil {
					panic(err)
				}
				tag = reflect.StructTag(value).Get("json")
			}
			tag = strings.Split(tag, ",")[0]
			if tag == "-" {
				continue
			}
			for _, name := range f.Names {
				if !name.IsExported() {
					continue
				}
				jsonName := tag
				if jsonName == "" {
					jsonName = name.Name
				}
				result = append(result, field{jsonName, signature(f.Type)})
			}
		}
		return result
	}
	models := map[string]model{}
	for name, expr := range types {
		_, isStruct := expr.(*ast.StructType)
		kind := "alias"
		if isStruct {
			kind = "struct"
		}
		models[name] = model{kind, fields(expr, map[string]bool{}), signature(expr)}
	}
	out := map[string]any{"reference_revision": inv.Reference.Revision, "models": models}
	encoder := json.NewEncoder(os.Stdout)
	encoder.SetIndent("", "  ")
	if err = encoder.Encode(out); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
