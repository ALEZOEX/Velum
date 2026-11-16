//go:build linux

package main

import (
	"fmt"
	"net"
	"net/netip"
	"sort"

	"golang.org/x/sys/unix"
)

// Keep CIDR classification (including preceding DNS/reject/proxy rules) in the
// core. Only its already physically sourced direct sockets and their reverse
// path validation need a main-table lookup before the TUN catch-all.
func tunDirectReturnRules(cfg map[string]any, sources []netip.Addr, mark uint32) ([]tunObject, error) {
	route, _ := cfg["route"].(map[string]any)
	rules, _ := route["rules"].([]any)
	prefixes := map[netip.Prefix]bool{}
	for _, raw := range rules {
		r, ok := raw.(map[string]any)
		if !ok || r["action"] != "route" || r["outbound"] != "direct" || len(r) != 3 {
			continue
		}
		values, e := tunStrings(r["ip_cidr"])
		if e != nil {
			return nil, e
		}
		for _, value := range values {
			p, e := netip.ParsePrefix(value)
			if e != nil {
				return nil, e
			}
			prefixes[p.Masked()] = true
		}
	}
	ordered := make([]netip.Prefix, 0, len(prefixes))
	for p := range prefixes {
		ordered = append(ordered, p)
	}
	sort.Slice(ordered, func(i, j int) bool { return ordered[i].String() < ordered[j].String() })
	seen := map[netip.Addr]bool{}
	var objects []tunObject
	for _, source := range sources {
		source = source.Unmap()
		if !source.IsValid() || source.IsUnspecified() || source.IsMulticast() || seen[source] {
			continue
		}
		seen[source] = true
		family := unix.AF_INET
		if source.Is6() {
			family = unix.AF_INET6
		}
		for _, p := range ordered {
			if source.Is4() != p.Addr().Is4() {
				continue
			}
			for _, action := range []int{unix.FR_ACT_TO_TBL, unix.FR_ACT_UNREACHABLE} {
				table := 0
				if action == unix.FR_ACT_TO_TBL {
					table = unix.RT_TABLE_MAIN
				}
				o := tunRule(family, linuxTUNRuleStart, table, action, mark)
				o = tunPrefix(tunPrefix(o, netip.PrefixFrom(source, source.BitLen()), true), p, false)
				o = tunSetAttr(o, unix.FRA_UID_RANGE, make([]byte, 8)) // Root core and kernel RPF lookup, never ordinary user sockets.
				objects = append(objects, o)
			}
		}
	}
	return objects, nil
}
func tunUplinkSources(iface string) ([]netip.Addr, error) {
	link, e := net.InterfaceByName(iface)
	if e != nil {
		return nil, e
	}
	addresses, e := link.Addrs()
	if e != nil {
		return nil, e
	}
	var sources []netip.Addr
	for _, a := range addresses {
		p, e := netip.ParsePrefix(a.String())
		if e != nil {
			return nil, fmt.Errorf("TUN uplink address %q: %w", a, e)
		}
		sources = append(sources, p.Addr())
	}
	return sources, nil
}
