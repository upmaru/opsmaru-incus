package main

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

type serverRoute struct {
	Pair   string `json:"pair"`
	Source string `json:"source"`
	Symbol string `json:"symbol"`
}

// Read only public api10 registrations. Internal, OS, UI and OIDC routes are
// separate server surfaces, not workload REST contracts of this client.
func serverRoutes(root string) ([]serverRoute, map[string]string, error) {
	files, err := filepath.Glob(filepath.Join(root, "cmd/incusd/*.go"))
	if err != nil {
		return nil, nil, err
	}
	definitions := map[string]*ast.CompositeLit{}
	sources := map[string]string{}
	hashes := map[string]string{}
	var registered []string
	for _, file := range files {
		data, err := os.ReadFile(file)
		if err != nil {
			return nil, nil, err
		}
		tree, err := parser.ParseFile(token.NewFileSet(), file, data, 0)
		if err != nil {
			return nil, nil, err
		}
		if filepath.Base(file) == "api.go" {
			digest := sha256.Sum256(data)
			hashes["cmd/incusd/api.go"] = hex.EncodeToString(digest[:])
		}
		for _, declaration := range tree.Decls {
			decl, ok := declaration.(*ast.GenDecl)
			if !ok || decl.Tok != token.VAR {
				continue
			}
			for _, item := range decl.Specs {
				value := item.(*ast.ValueSpec)
				if len(value.Names) != 1 || len(value.Values) != 1 {
					continue
				}
				literal, ok := value.Values[0].(*ast.CompositeLit)
				if !ok {
					continue
				}
				name := value.Names[0].Name
				if name == "api10" {
					for _, element := range literal.Elts {
						id, ok := element.(*ast.Ident)
						if !ok {
							return nil, nil, fmt.Errorf("unsupported api10 registration")
						}
						registered = append(registered, id.Name)
					}
				}
				if id, ok := literal.Type.(*ast.Ident); ok && id.Name == "APIEndpoint" {
					definitions[name] = literal
					sources[name] = "cmd/incusd/" + filepath.Base(file)
					digest := sha256.Sum256(data)
					hashes[sources[name]] = hex.EncodeToString(digest[:])
				}
			}
		}
	}
	var routes []serverRoute
	for _, name := range registered {
		literal := definitions[name]
		if literal == nil {
			return nil, nil, fmt.Errorf("missing registration %s", name)
		}
		path := "/1.0"
		var verbs []string
		var suffixes []*ast.CompositeLit
		for _, element := range literal.Elts {
			field := element.(*ast.KeyValueExpr)
			key := field.Key.(*ast.Ident).Name
			if key == "Path" {
				text, err := strconv.Unquote(field.Value.(*ast.BasicLit).Value)
				if err != nil {
					return nil, nil, err
				}
				path += "/" + text
			}
			if key == "SuffixActions" {
				for _, suffix := range field.Value.(*ast.CompositeLit).Elts {
					suffixes = append(suffixes, suffix.(*ast.CompositeLit))
				}
			}
			switch key {
			case "Get", "Post", "Put", "Patch", "Delete", "Head", "Options":
				verbs = append(verbs, strings.ToUpper(key))
			}
		}
		for _, verb := range verbs {
			routes = append(routes, serverRoute{verb + " " + path, sources[name], name})
		}
		for _, suffix := range suffixes {
			var tail string
			var actions []string
			for _, element := range suffix.Elts {
				field := element.(*ast.KeyValueExpr)
				key := field.Key.(*ast.Ident).Name
				if key == "Name" {
					tail, err = strconv.Unquote(field.Value.(*ast.BasicLit).Value)
					if err != nil {
						return nil, nil, err
					}
				}
				switch key {
				case "Get", "Post", "Put", "Patch", "Delete", "Head", "Options":
					actions = append(actions, strings.ToUpper(key))
				}
			}
			for _, verb := range actions {
				routes = append(routes, serverRoute{verb + " " + path + tail, sources[name], name})
			}
		}
	}
	if len(routes) == 0 {
		return nil, nil, fmt.Errorf("empty api10 registrations")
	}
	return routes, hashes, nil
}
