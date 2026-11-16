// This version-only fixture has no networking capability. It lets SCM exercise
// the real daemon startup without shipping or starting a VPN engine in CI.
package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

func main() {
	if len(os.Args) == 2 && os.Args[1] == "version" {
		if strings.EqualFold(filepath.Base(os.Args[0]), "xray.exe") {
			fmt.Println("Xray 26.10.31 F1 inert CI fixture")
		} else {
			fmt.Println("sing-box version 1.12.12")
		}
		return
	}
	fmt.Fprintln(os.Stderr, "F1 fixture refuses all engine commands")
	os.Exit(97)
}
