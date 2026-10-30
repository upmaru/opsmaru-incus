// Fixture-only unchanged pkg/sftp v1.13.10 server over stdin/stdout, rooted in the
// private temporary directory given as its only argument. The test relays one
// upgraded SFTP connection to it; it never listens or touches other host paths.
package main

import (
	"io"
	"os"

	"github.com/pkg/sftp"
)

type stdio struct {
	io.Reader
	io.Writer
}

func (stdio) Close() error { return os.Stdout.Close() }

func main() {
	if len(os.Args) != 2 {
		panic("usage: sftpserver ROOT")
	}
	if err := os.Chdir(os.Args[1]); err != nil {
		panic(err)
	}
	server, err := sftp.NewServer(stdio{os.Stdin, os.Stdout}, sftp.WithServerWorkingDirectory(os.Args[1]))
	if err != nil {
		panic(err)
	}
	if err := server.Serve(); err != nil && err != io.EOF {
		panic(err)
	}
}
