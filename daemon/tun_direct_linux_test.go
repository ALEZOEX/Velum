//go:build linux

package main

import (
	"bytes"
	"net/netip"
	"testing"

	"golang.org/x/sys/unix"
)

func TestTUNDirectReturnScope(t *testing.T) {
	cfg, e := buildConfig(validVLESS, true, "", ConnectionSettings{})
	mustF2(t, e)
	mustF2(t, applyExclusions(cfg, []string{"198.19.0.0/24", "198.19.0.0/24", "198.19.0.0/25", "fd00:19::/64", "example.org"}))
	objects, e := tunDirectReturnRules(cfg, []netip.Addr{netip.MustParseAddr("198.18.0.1"), netip.MustParseAddr("198.18.0.1"), netip.MustParseAddr("fd00:18::1")}, 123456)
	mustF2(t, e)
	if len(objects) != 6 {
		t.Fatalf("expected three deduplicated CIDRs with lookup/failure pairs; got %d", len(objects))
	}
	for i := 0; i < len(objects); i += 2 {
		lookup, terminal := objects[i], objects[i+1]
		attrs, e := tunAttrs(lookup.Wire)
		mustF2(t, e)
		if !lookup.marked(123456) || !terminal.marked(123456) {
			t.Fatal("new policy escaped journal ownership")
		}
		if tunValue(attrs, unix.FRA_PRIORITY) != linuxTUNRuleStart || tunValue(attrs, unix.FRA_TABLE) != unix.RT_TABLE_MAIN {
			t.Fatal("direct return must precede TUN lookup in owned range")
		}
		bits := byte(32)
		if lookup.Wire[0] == unix.AF_INET6 {
			bits = 128
		}
		if lookup.Wire[2] != bits || len(attrs[unix.FRA_SRC]) == 0 || len(attrs[unix.FRA_DST]) == 0 {
			t.Fatal("source or destination was broadened")
		}
		if !bytes.Equal(attrs[unix.FRA_UID_RANGE], make([]byte, 8)) {
			t.Fatal("unprivileged sockets can bypass application routing")
		}
		if lookup.Wire[7] != unix.FR_ACT_TO_TBL || terminal.Wire[7] != unix.FR_ACT_UNREACHABLE {
			t.Fatal("missing direct-route failure barrier")
		}
	}
	in, _ := linuxTUNInbound(cfg)
	if _, exists := in["route_exclude_address"]; exists {
		t.Fatal("CIDR exclusions bypassed DNS hijack and application rules")
	}
	rules := cfg["route"].(map[string]any)["rules"].([]any)
	if rules[1].(map[string]any)["action"] != "hijack-dns" {
		t.Fatal("DNS lost precedence")
	}
}
func TestTUNDirectReturnDoesNotBroadenConditionalRules(t *testing.T) {
	cfg := map[string]any{"route": map[string]any{"rules": []any{
		map[string]any{"action": "route", "outbound": "proxy", "ip_cidr": []string{"0.0.0.0/0"}},
		map[string]any{"action": "route", "outbound": "direct", "ip_cidr": []string{"0.0.0.0/0"}, "port": 443},
		map[string]any{"action": "route", "outbound": "direct", "domain_suffix": []string{"example.org"}},
	}}}
	rules, e := tunDirectReturnRules(cfg, []netip.Addr{netip.MustParseAddr("198.18.0.1")}, 123456)
	mustF2(t, e)
	if len(rules) != 0 {
		t.Fatal("conditional/domain/proxy policy turned into unconditional CIDR bypass")
	}
}

func TestTUNPinnedEndpointRejectsAmbiguousExclusions(t *testing.T) {
	for _, values := range [][]string{
		nil, {"198.18.0.3/32", "198.18.0.2/32"}, {"198.18.0.0/24"},
		{"fd00:18::/64"}, {"bad"}, {"::ffff:198.18.0.3/128"},
		{"0.0.0.0/32"}, {"ff02::1/128"}, {"172.28.0.1/32"}, {"fdfe:7665:6c75::2/128"},
	} {
		if _, err := tunPinnedEndpoint(map[string]any{"route_exclude_address": values}); err == nil {
			t.Fatalf("unexpected endpoint admission: %v", values)
		}
	}
}

func TestTUNEndpointTransportScope(t *testing.T) {
	const mark, tunIndex = 467893, 12
	for _, tc := range []struct {
		host    string
		appIPv6 bool
	}{
		{"198.18.0.3/32", true}, {"fd00:18::3/128", true}, {"fd00:18::3/128", false},
	} {
		in, err := linuxTUNInbound(tunTestConfig(t, tc.appIPv6))
		mustF2(t, err)
		in["route_exclude_address"] = []string{tc.host}
		ip, err := tunPinnedEndpoint(in)
		mustF2(t, err)
		rules := tunEndpointTransportRules(ip, mark)
		if len(rules) != 2 {
			t.Fatalf("%s: missing physical lookup/failure pair", ip)
		}
		family := byte(unix.AF_INET)
		if ip.Is6() {
			family = unix.AF_INET6
		}
		for i, rule := range rules {
			attrs, err := tunAttrs(rule.Wire)
			mustF2(t, err)
			if !rule.marked(mark) || rule.Wire[0] != family || int(rule.Wire[1]) != ip.BitLen() ||
				!bytes.Equal(attrs[unix.FRA_DST], ip.AsSlice()) || tunValue(attrs, unix.FRA_PRIORITY) != linuxTUNRuleStart ||
				!bytes.Equal(attrs[unix.FRA_UID_RANGE], make([]byte, 8)) {
				t.Fatalf("transport escape is broader than root to pinned %s, or missing ownership: %+v", ip, attrs)
			}
			if i == 0 && (tunValue(attrs, unix.FRA_TABLE) != unix.RT_TABLE_MAIN || rule.Wire[7] != unix.FR_ACT_TO_TBL) ||
				i == 1 && rule.Wire[7] != unix.FR_ACT_UNREACHABLE {
				t.Fatalf("missing physical lookup/failure barrier for %s", ip)
			}
		}
		objects, err := tunPlan(in, tunIndex, mark)
		mustF2(t, err)
		covered, prohibited := false, false
		for _, o := range objects {
			if o.Wire[0] != family {
				continue
			}
			attrs, err := tunAttrs(o.Wire)
			mustF2(t, err)
			if o.Kind == "rule" && o.Wire[7] == unix.FR_ACT_UNREACHABLE && tunValue(attrs, unix.FRA_PRIORITY) > linuxTUNRuleStart {
				prohibited = true
			}
			if o.Kind == "route" && o.Wire[1] != 0 && tunValue(attrs, unix.RTA_OIF) == tunIndex &&
				tunValue(attrs, unix.RTA_TABLE) == linuxTUNTable && o.marked(mark) {
				dst, ok := netip.AddrFromSlice(attrs[unix.RTA_DST])
				covered = covered || ok && netip.PrefixFrom(dst, int(o.Wire[1])).Contains(ip)
			}
		}
		enabled := ip.Is4() || tc.appIPv6
		if covered != enabled || prohibited == enabled {
			t.Fatalf("application traffic to %s (IPv6 %t) has TUN coverage %t, prohibition %t", ip, tc.appIPv6, covered, prohibited)
		}
	}
}

// UDP connect performs only a local FIB lookup. Nothing is sent; no TUN,
// namespace, administrative permissions or system configuration is required.
func TestEndpointPhysicalRouteLookup(t *testing.T) {
	loopback := netip.MustParseAddr("127.0.0.1")
	if err := validateEndpointPhysicalRoute(loopback, "lo"); err != nil {
		t.Fatalf("explicit local SOCKS endpoint lost its route: %v", err)
	}
	for _, tc := range []struct {
		ip    netip.Addr
		iface string
	}{
		{netip.Addr{}, "lo"}, {loopback, ""}, {loopback, "velum0"}, {loopback, "velum-no-exist"},
		{netip.MustParseAddr("198.18.0.2"), "lo"},
	} {
		if err := validateEndpointPhysicalRoute(tc.ip, tc.iface); err == nil {
			t.Fatalf("accepted invalid endpoint route %v via %q", tc.ip, tc.iface)
		}
	}
}
