//go:build linux

package main

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

// UDP connect performs a routing lookup, not a transport probe: no datagram is
// sent. Run after old ownership has been cleaned and before starting the core.
func validateEndpointPhysicalRoute(ip netip.Addr, iface string) error {
	if !ip.IsValid() || iface == "" || iface == "velum0" {
		return fmt.Errorf("invalid physical endpoint path: %v via %q", ip, iface)
	}
	link, err := net.InterfaceByName(iface)
	if err != nil {
		return err
	}
	if link.Flags&net.FlagUp == 0 || (link.Flags&net.FlagLoopback != 0) != ip.IsLoopback() {
		return fmt.Errorf("endpoint %s is incompatible with interface %s", ip, iface)
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	dialer := net.Dialer{Control: func(_, _ string, c syscall.RawConn) error {
		var optionErr error
		e := c.Control(func(fd uintptr) {
			optionErr = unix.SetsockoptString(int(fd), unix.SOL_SOCKET, unix.SO_BINDTODEVICE, iface)
		})
		if e != nil {
			return e
		}
		return optionErr
	}}
	conn, e := dialer.DialContext(ctx, "udp", net.JoinHostPort(ip.String(), "9"))
	if e != nil {
		return fmt.Errorf("Нет безопасного физического маршрута к endpoint %s через %s: %w", ip, iface, e)
	}
	defer conn.Close()
	source, ok := conn.LocalAddr().(*net.UDPAddr)
	if !ok {
		return errors.New("unknown endpoint socket address")
	}
	selected, ok := netip.AddrFromSlice(source.IP)
	if !ok {
		return errors.New("invalid endpoint source address")
	}
	addresses, e := link.Addrs()
	if e != nil {
		return e
	}
	for _, a := range addresses {
		p, e := netip.ParsePrefix(a.String())
		if e == nil && p.Addr().Unmap() == selected.Unmap() {
			return nil
		}
	}
	return fmt.Errorf("endpoint source %s does not belong to physical interface %s", selected, iface)
}
