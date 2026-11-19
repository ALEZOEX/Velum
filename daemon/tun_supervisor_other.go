//go:build !linux

package main

import (
	"context"
	"errors"
	"io"
	"os/exec"
)

func runTUNCommand(_ []string) (bool, error) { return false, nil }
func recoverAllowedTUN(_ bool) error         { return nil }
func recoverTUN() error                      { return nil }
func startManagedTUN(_, _ string, _ io.Writer) (*exec.Cmd, chan struct{}, io.Closer, string, error) {
	return nil, nil, nil, "", errors.New("Linux TUN supervisor unavailable")
}

func startManagedTUNContext(_ context.Context, core, path string, logs io.Writer) (*exec.Cmd, chan struct{}, io.Closer, string, error) {
	return startManagedTUN(core, path, logs)
}
