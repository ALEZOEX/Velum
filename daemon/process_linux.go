//go:build linux

package main

import (
	"os"
	"os/exec"
	"syscall"
)

// configureChild applies Linux-specific process lifetime attributes to child processes.
// SysProcAttr.Pdeathsig = syscall.SIGTERM instructs the Linux kernel to deliver
// SIGTERM to the child process immediately if the parent (velumd) terminates for any
// reason (including SIGKILL, panic, or unhandled crash).
//
// Setpgid is deliberately omitted: moving the child into an independent process
// group does not clean it up and would detach it from terminal signal delivery
// in console mode. Pdeathsig operates at kernel level independently of process groups.
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
