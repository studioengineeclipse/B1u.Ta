// Go conformance entrypoint (SPEC/20-b1-canon-1.md §5).
//
//	stdin  : a JSON document
//	stdout : 64 lowercase hex digits + newline
//	stderr : a B1_ERR_* token when the document is rejected
package main

import (
	"fmt"
	"io"
	"os"

	"b1/engine/internal/canon"
)

func main() {
	data, err := io.ReadAll(os.Stdin)
	if err != nil {
		fmt.Fprintln(os.Stderr, "B1_ERR_PARSE")
		os.Exit(2)
	}
	digest, err := canon.DigestText(string(data))
	if err != nil {
		fmt.Fprintln(os.Stderr, canon.Token(err))
		os.Exit(2)
	}
	fmt.Println(digest)
}
