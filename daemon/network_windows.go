//go:build windows

package main

import (
	"log"
	"os/exec"
	"syscall"
)

const velumAdapter = "Velum"

// cleanupNetworkState removes only routes that sing-box creates on the Velum
// adapter when auto_route is active. It never touches physical adapters.
// This is a safety net for abnormal engine termination; normal shutdown is
// already handled by sing-box itself.
func cleanupNetworkState(tunWasActive bool) {
	if !tunWasActive {
		return
	}
	for _, route := range []struct {
		family  string
		prefix  string
		adapter string
	}{
		{"ipv4", "0.0.0.0/1", velumAdapter},
		{"ipv4", "128.0.0.0/1", velumAdapter},
		{"ipv6", "::/1", velumAdapter},
		{"ipv6", "8000::/1", velumAdapter},
	} {
		command := exec.Command("netsh", "interface", route.family, "delete", "route", route.prefix, route.adapter)
		command.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
		if output, err := command.CombinedOutput(); err != nil {
			log.Printf("cleanup route %s: %v: %s", route.prefix, err, output)
		}
	}
	for _, family := range []string{"ipv4", "ipv6"} {
		command := exec.Command("netsh", "interface", family, "set", "dnsservers", "name="+velumAdapter, "source=dhcp")
		command.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
		_ = command.Run()
	}
}
