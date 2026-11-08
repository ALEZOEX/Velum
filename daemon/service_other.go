//go:build !windows

package main

import "errors"

func runServiceAction(_ string, _ daemonConfig, _ string) error {
	return errors.New("service mode is available on Windows only")
}
