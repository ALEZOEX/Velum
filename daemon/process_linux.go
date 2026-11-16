//go:build linux

package main

import (
	"os"
	"os/exec"
	"syscall"
)

// Pdeathsig is tied to the spawning OS thread and requests a signal, not
// guaranteed cleanup. The TUN supervisor pins that thread and also uses an
// EOF lifeline and a durable journal; it deliberately has no Pdeathsig itself.
// Keep children in the terminal/systemd process group.
func configureChild(cmd *exec.Cmd) {
	if cmd.SysProcAttr == nil {
		cmd.SysProcAttr = &syscall.SysProcAttr{}
	}
	cmd.SysProcAttr.Pdeathsig = syscall.SIGTERM
}

func afterStart(_ *exec.Cmd) error {
	return nil
}

func interruptProcess(cmd *exec.Cmd) {
	if cmd == nil || cmd.Process == nil {
		return
	}
	_ = cmd.Process.Signal(os.Interrupt)
}
