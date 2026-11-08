//go:build !windows

package main

import (
	"os"
	"os/exec"
)

func configureChild(_ *exec.Cmd)   {}
func afterStart(_ *exec.Cmd) error { return nil }

func interruptProcess(cmd *exec.Cmd) {
	if cmd == nil || cmd.Process == nil {
		return
	}
	_ = cmd.Process.Signal(os.Interrupt)
}
