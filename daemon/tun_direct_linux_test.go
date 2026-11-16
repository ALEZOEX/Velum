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
