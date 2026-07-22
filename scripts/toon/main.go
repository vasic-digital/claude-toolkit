// main.go — CLI for the Go port of scripts/toon_encode.py.
//
// Byte-compatible with the Python wrapper's command-line interface:
//
//	toon_encode '{"users":[{"id":1,"name":"Alice"}]}'   # positional JSON
//	toon_encode --file data.json                          # -f/--file
//	echo '{"data":...}' | toon_encode                     # stdin
//
// Flags: --file/-f <path>, --compact (accepted, no-op — matches the Python
// wrapper, whose --compact never affected output). Output is the TOON encoding
// followed by a trailing newline (Python print()). Invalid JSON exits non-zero.
//
// Cross-reference: scripts/toon_encode.py (the original), docs/scripts (guide).
package main

import (
	"fmt"
	"io"
	"os"
)

func main() {
	os.Exit(run(os.Args[1:], os.Stdin, os.Stdout, os.Stderr))
}

func run(argv []string, stdin io.Reader, stdout, stderr io.Writer) int {
	var input, file string
	haveInput := false

	// Minimal argparse-compatible parsing for the documented flags. Unknown
	// flags are reported as an error (argparse-equivalent), positional input is
	// the first non-flag argument.
	for i := 0; i < len(argv); i++ {
		arg := argv[i]
		switch {
		case arg == "--file" || arg == "-f":
			if i+1 >= len(argv) {
				fmt.Fprintln(stderr, "error: argument --file/-f: expected one argument")
				return 2
			}
			i++
			file = argv[i]
		case len(arg) > len("--file=") && arg[:len("--file=")] == "--file=":
			file = arg[len("--file="):]
		case arg == "--compact":
			// Accepted for compatibility; no effect (matches the Python wrapper).
		case arg == "-h" || arg == "--help":
			fmt.Fprintln(stdout, "usage: toon_encode [-h] [--file FILE] [--compact] [input]")
			return 0
		case len(arg) > 0 && arg[0] == '-' && arg != "-":
			fmt.Fprintf(stderr, "error: unrecognized arguments: %s\n", arg)
			return 2
		default:
			if !haveInput {
				input = arg
				haveInput = true
			}
		}
	}

	var raw []byte
	var err error
	switch {
	case file != "":
		raw, err = os.ReadFile(file)
		if err != nil {
			fmt.Fprintf(stderr, "error: %v\n", err)
			return 1
		}
	case input != "":
		raw = []byte(input)
	default:
		raw, err = io.ReadAll(stdin)
		if err != nil {
			fmt.Fprintf(stderr, "error: %v\n", err)
			return 1
		}
	}

	data, err := parseOrdered(raw)
	if err != nil {
		fmt.Fprintf(stderr, "error: invalid JSON: %v\n", err)
		return 1
	}

	fmt.Fprintln(stdout, encodeToon(data))
	return 0
}
