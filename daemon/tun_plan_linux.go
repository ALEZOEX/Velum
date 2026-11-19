//go:build linux

package main

import (
	"errors"
	"net/netip"

	"golang.org/x/sys/unix"
)

func linuxTUNInbound(cfg map[string]any) (map[string]any, error) {
	list, _ := cfg["inbounds"].([]any)
	var tun map[string]any
	for _, raw := range list {
		in, ok := raw.(map[string]any)
		if ok && in["type"] == "tun" {
			if tun != nil {
				return nil, errors.New("multiple TUN inbounds")
			}
			tun = in
		}
	}
	if tun == nil {
		return nil, errors.New("missing TUN inbound")
	}
	return tun, nil
}
func tunStrings(v any) ([]string, error) {
	switch values := v.(type) {
	case []string:
		return values, nil
	case []any:
		r := make([]string, 0, len(values))
		for _, v := range values {
			s, ok := v.(string)
			if !ok {
				return nil, errors.New("invalid TUN address")
			}
			r = append(r, s)
		}
		return r, nil
	case nil:
		return nil, nil
	}
	return nil, errors.New("invalid TUN address list")
}
func tunAddresses(in map[string]any, key string) ([]netip.Prefix, error) {
	values, err := tunStrings(in[key])
	if err != nil {
		return nil, err
	}
	var result []netip.Prefix
	for _, v := range values {
		p, e := netip.ParsePrefix(v)
		if e != nil {
			return nil, e
		}
		result = append(result, p)
	}
	return result, nil
}
func subtractTUNPrefix(p, exclude netip.Prefix) []netip.Prefix {
	if !p.Overlaps(exclude) {
		return []netip.Prefix{p}
	}
	if exclude.Bits() <= p.Bits() {
		return nil
	}
	bits := p.Bits() + 1
	a := p.Addr()
	var other netip.Addr
	if a.Is4() {
		b := a.As4()
		b[p.Bits()/8] |= 1 << uint(7-p.Bits()%8)
		other = netip.AddrFrom4(b)
	} else {
		b := a.As16()
		b[p.Bits()/8] |= 1 << uint(7-p.Bits()%8)
		other = netip.AddrFrom16(b)
	}
	return append(subtractTUNPrefix(netip.PrefixFrom(a, bits), exclude), subtractTUNPrefix(netip.PrefixFrom(other, bits), exclude)...)
}

// Equivalent to the supported subset of sing-tun v0.7.3 Linux rules(): no UID,
// interface filters or auto_redirect. Marker mask zero matches every packet;
// it identifies the rule without setting packet marks or changing selectors.
func tunPlan(in map[string]any, index int, mark uint32) ([]tunObject, error) {
	addrs, err := tunAddresses(in, "address")
	if err != nil {
		return nil, err
	}
	excludes, err := tunAddresses(in, "route_exclude_address")
	if err != nil {
		return nil, err
	}
	var objects []tunObject
	for _, family := range []int{unix.AF_INET, unix.AF_INET6} {
		var addresses []netip.Prefix
		for _, p := range addrs {
			if p.Addr().Is4() == (family == unix.AF_INET) {
				addresses = append(addresses, p)
			}
		}
		p := linuxTUNRuleStart + 1 // First slot is reserved for physically sourced direct return paths.
		nop := linuxTUNRuleEnd
		if len(addresses) == 0 {
			objects = append(objects, tunRule(family, p, 0, unix.FR_ACT_UNREACHABLE, mark))
			continue
		}
		base := netip.MustParsePrefix("0.0.0.0/0")
		if family == unix.AF_INET6 {
			base = netip.MustParsePrefix("::/0")
		}
		ranges := []netip.Prefix{base}
		for _, exclude := range excludes {
			var next []netip.Prefix
			for _, prefix := range ranges {
				next = append(next, subtractTUNPrefix(prefix, exclude.Masked())...)
			}
			ranges = next
		}
		for _, prefix := range ranges {
			objects = append(objects, tunRoute(prefix, index, mark))
		}
		// The transport-specific rules already bypass the TUN for the daemon's
		// UID. Fill the former host-wide exception for other UIDs. Keep the
		// split routes above: an aggregated /0 is suppressed by the early
		// table lookup and would change precedence for unrelated traffic.
		for _, endpoint := range excludes {
			if endpoint.Addr().Is4() == (family == unix.AF_INET) {
				objects = append(objects, tunRoute(endpoint, index, mark))
			}
		}
		var rules []tunObject
		lookup := func(priority, table int) tunObject { return tunRule(family, priority, table, unix.FR_ACT_TO_TBL, mark) }
		goTo := func(priority int) tunObject {
			return tunSetAttr(tunRule(family, priority, 0, unix.FR_ACT_GOTO, mark), unix.FRA_GOTO, tunU32(uint32(nop)))
		}
		iif := func(o tunObject, name string) tunObject {
			return tunSetAttr(o, unix.FRA_IIFNAME, append([]byte(name), 0))
		}
		if family == unix.AF_INET {
			for _, address := range addresses {
				rules = append(rules, tunPrefix(lookup(p, linuxTUNTable), address.Masked(), false))
			}
			p++
		}
		rules = append(rules, tunSetAttr(lookup(p, linuxTUNTable), unix.FRA_SUPPRESS_PREFIXLEN, tunU32(0)))
		p++
		dns := tunSetAttr(lookup(p, unix.RT_TABLE_MAIN), unix.FRA_SUPPRESS_PREFIXLEN, tunU32(0))
		port := []byte{0, 0, 0, 0}
		tunEndian.PutUint16(port, 53)
		tunEndian.PutUint16(port[2:], 53)
		rules = append(rules, tunInvert(tunSetAttr(dns, unix.FRA_DPORT_RANGE, port)))
		rules = append(rules, iif(goTo(p), "velum0"))
		p++
		if family == unix.AF_INET {
			rules = append(rules, tunInvert(iif(lookup(p, linuxTUNTable), "lo")))
			rules = append(rules, tunPrefix(iif(lookup(p, linuxTUNTable), "lo"), netip.MustParsePrefix("0.0.0.0/32"), true))
		} else {
			// rules() uses the previous priority for the two loopback goto rules.
			for _, prefix := range []string{"::/1", "8000::/1"} {
				rules = append(rules, tunPrefix(iif(goTo(p-1), "lo"), netip.MustParsePrefix(prefix), true))
			}
		}
		for _, address := range addresses {
			rules = append(rules, tunPrefix(iif(lookup(p, linuxTUNTable), "lo"), address.Masked(), true))
		}
		if family == unix.AF_INET6 {
			p++
			rules = append(rules, lookup(p, linuxTUNTable))
		}
		// Install goto target first to avoid transient unresolved jumps. Recovery and
		// rollback track the actual attempted object sequence, not a priority range.
		objects = append(objects, tunRule(family, nop, 0, unix.FR_ACT_NOP, mark))
		objects = append(objects, rules...)
	}
	return objects, nil
}
