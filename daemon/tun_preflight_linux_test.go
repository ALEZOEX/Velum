//go:build linux

package main

import (
	"errors"
	"net"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/sagernet/netlink"
	"golang.org/x/sys/unix"
)

type memoryTUNResources struct {
	links  []netlink.Link
	rules  map[int][]netlink.Rule
	routes map[int][]netlink.Route
	addrs  map[int][]netlink.Addr
	fail   string
	calls  []string
	t      *testing.T
}

func (m *memoryTUNResources) LinkList() ([]netlink.Link, error) {
	m.calls = append(m.calls, "links")
	return m.links, m.failure("links")
}
func (m *memoryTUNResources) AddrList(link netlink.Link, family int) ([]netlink.Addr, error) {
	if link != nil {
		m.t.Fatal("must check addresses on all links")
	}
	key := familyName(family) + " addresses"
	m.calls = append(m.calls, key)
	return m.addrs[family], m.failure(key)
}
func (m *memoryTUNResources) RuleList(family int) ([]netlink.Rule, error) {
	key := familyName(family) + " rules"
	m.calls = append(m.calls, key)
	return m.rules[family], m.failure(key)
}
func (m *memoryTUNResources) RouteListFiltered(family int, filter *netlink.Route, mask uint64) ([]netlink.Route, error) {
	if filter == nil || filter.Table != unix.RT_TABLE_UNSPEC || mask != netlink.RT_FILTER_TABLE {
		m.t.Fatal("must dump all routing tables, not only main")
	}
	key := familyName(family) + " routes"
	m.calls = append(m.calls, key)
	return m.routes[family], m.failure(key)
}
func (m *memoryTUNResources) failure(key string) error {
	if m.fail == key {
		return errors.New("simulated netlink failure")
	}
	return nil
}
func familyName(family int) string {
	if family == netlink.FAMILY_V4 {
		return "IPv4"
	}
	return "IPv6"
}
func tunTestConfig(t *testing.T, ipv6 bool) map[string]any {
	t.Helper()
	cfg, err := buildConfigForOS(map[string]any{"type": "socks", "tag": "proxy", "server": "192.0.2.1", "server_port": 1080}, true, "", ConnectionSettings{IPv6: &ipv6}, "linux")
	if err != nil {
		t.Fatal(err)
	}
	return cfg
}
func ipNet(value string) *net.IPNet {
	_, prefix, err := net.ParseCIDR(value)
	if err != nil {
		panic(err)
	}
	return prefix
}

func TestTUNPreflightFreeResources(t *testing.T) {
	for _, ipv6 := range []bool{false, true} {
		t.Run(map[bool]string{false: "IPv4_only", true: "dual_stack"}[ipv6], func(t *testing.T) {
			m := &memoryTUNResources{t: t, rules: map[int][]netlink.Rule{
				netlink.FAMILY_V4: {{Priority: 9000, Table: 2022}, {Priority: 5270, Table: 52}, {Priority: 32766, Table: 254}},
				netlink.FAMILY_V6: {{Priority: 9000, Table: 2022}},
			}, routes: map[int][]netlink.Route{netlink.FAMILY_V4: {{Table: 2022, Dst: ipNet("0.0.0.0/1")}}}}
			if err := checkLinuxTUNResources(tunTestConfig(t, ipv6), m); err != nil {
				t.Fatal(err)
			}
			want := []string{"links", "IPv4 rules", "IPv4 routes", "IPv4 addresses", "IPv6 rules", "IPv6 routes", "IPv6 addresses"}
			if !reflect.DeepEqual(m.calls, want) {
				t.Fatalf("incomplete checks: %v", m.calls)
			}
		})
	}
}

func TestTUNPreflightRejectsEveryCleanupPriority(t *testing.T) {
	for _, family := range []int{netlink.FAMILY_V4, netlink.FAMILY_V6} {
		for priority := linuxTUNRuleStart; priority <= linuxTUNRuleEnd; priority++ {
			m := &memoryTUNResources{t: t, rules: map[int][]netlink.Rule{family: {{Priority: priority, Table: 999}}}}
			before := append([]netlink.Rule(nil), m.rules[family]...)
			err := checkLinuxTUNResources(tunTestConfig(t, false), m)
			if err == nil || !strings.Contains(err.Error(), familyName(family)+" policy rule") {
				t.Fatalf("priority %d: %v", priority, err)
			}
			if !reflect.DeepEqual(m.rules[family], before) {
				t.Fatal("foreign rules changed")
			}
		}
	}
}

func TestTUNPreflightRejectsReferencedOrOccupiedResources(t *testing.T) {
	for _, family := range []int{netlink.FAMILY_V4, netlink.FAMILY_V6} {
		for _, tc := range []struct {
			name    string
			rules   []netlink.Rule
			routes  []netlink.Route
			addrs   []netlink.Addr
			message string
		}{
			{"table_reference", []netlink.Rule{{Priority: 123, Table: linuxTUNTable}}, nil, nil, "ссылается на таблицу"},
			{"goto", []netlink.Rule{{Priority: 123, Goto: linuxTUNRuleEnd}}, nil, nil, "goto"},
			{"input_link", []netlink.Rule{{Priority: 123, IifName: "velum0"}}, nil, nil, "ссылается на velum0"},
			{"output_link", []netlink.Rule{{Priority: 123, OifName: "velum0"}}, nil, nil, "ссылается на velum0"},
			{"occupied_table", nil, []netlink.Route{{Table: linuxTUNTable}}, nil, "содержит маршрут"},
			{"connected_subnet", nil, []netlink.Route{{Table: 254, Scope: netlink.SCOPE_LINK, Dst: ipNet(map[int]string{netlink.FAMILY_V4: "172.28.0.0/16", netlink.FAMILY_V6: "fdfe:7665:6c75::/64"}[family])}}, nil, "пересекаются"},
			{"interface_address", nil, nil, []netlink.Addr{{IPNet: ipNet(map[int]string{netlink.FAMILY_V4: "172.28.0.2/32", netlink.FAMILY_V6: "fdfe:7665:6c75::2/128"}[family])}}, "пересекаются"},
		} {
			t.Run(familyName(family)+"/"+tc.name, func(t *testing.T) {
				m := &memoryTUNResources{t: t, rules: map[int][]netlink.Rule{family: tc.rules}, routes: map[int][]netlink.Route{family: tc.routes}, addrs: map[int][]netlink.Addr{family: tc.addrs}}
				err := checkLinuxTUNResources(tunTestConfig(t, true), m)
				if err == nil || !strings.Contains(err.Error(), tc.message) {
					t.Fatalf("unexpected error: %v", err)
				}
			})
		}
	}
	m := &memoryTUNResources{t: t, links: []netlink.Link{&netlink.Dummy{LinkAttrs: netlink.LinkAttrs{Name: "velum0"}}}}
	if err := checkLinuxTUNResources(tunTestConfig(t, true), m); err == nil || !strings.Contains(err.Error(), "интерфейс velum0 уже существует") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestTUNPreflightFailsClosedOnInspectionError(t *testing.T) {
	for _, key := range []string{"links", "IPv4 rules", "IPv4 routes", "IPv4 addresses", "IPv6 rules", "IPv6 routes", "IPv6 addresses"} {
		t.Run(key, func(t *testing.T) {
			m := &memoryTUNResources{t: t, fail: key}
			err := checkLinuxTUNResources(tunTestConfig(t, true), m)
			if err == nil || !strings.Contains(err.Error(), "simulated netlink failure") {
				t.Fatalf("inspection failure was ignored: %v", err)
			}
		})
	}
}

func TestTUNPreflightRejectsUnsupportedConfig(t *testing.T) {
	for _, key := range []string{"auto_redirect", "iproute2_table_index", "iproute2_rule_index", "interface_name", "auto_route", "include_uid", "address"} {
		t.Run(key, func(t *testing.T) {
			cfg := tunTestConfig(t, true)
			cfg["inbounds"].([]any)[1].(map[string]any)[key] = "unexpected"
			m := &memoryTUNResources{t: t}
			if err := checkLinuxTUNResources(cfg, m); err == nil {
				t.Fatal("unchecked configuration accepted")
			}
			if len(m.calls) != 0 {
				t.Fatal("invalid config was inspected")
			}
		})
	}
}

// A fake core accepts check but makes run observable without touching any OS
// network resources. The same boundary guards normal and companion TUN starts.
func TestTUNConflictPreventsChildStart(t *testing.T) {
	dir := t.TempDir()
	core := filepath.Join(dir, "core")
	marker := filepath.Join(dir, "ran")
	if err := os.WriteFile(core, []byte("#!/bin/sh\nif [ \"$1\" = check ]; then exit 0; fi\ntouch \""+marker+"\"\nexit 1\n"), 0700); err != nil {
		t.Fatal(err)
	}
	for _, late := range []bool{false, true} {
		calls := 0
		s := &service{core: core, dir: dir, tun: true, state: "disconnected", tunPreflight: func(cfg map[string]any) error {
			calls++
			if late && calls == 1 {
				return nil
			}
			return errors.New("TUN не запущен: occupied IPv6 priority")
		}}
		err := s.connectRequest(ConnectRequest{URI: validVLESS, Settings: ConnectionSettings{Mode: "tun"}})
		if err == nil || !strings.Contains(err.Error(), "occupied IPv6") {
			t.Fatalf("conflict lost: %v", err)
		}
		s.stop()
		s.stop()
		if _, err = os.Stat(marker); !errors.Is(err, os.ErrNotExist) {
			t.Fatal("core run was invoked despite conflict")
		}
		if s.cmd != nil {
			t.Fatal("core process exists after rejected start")
		}
	}
}

func TestTUNRetryDoesNotAssumeStaleRulesAreOwned(t *testing.T) {
	m := &memoryTUNResources{t: t, rules: map[int][]netlink.Rule{netlink.FAMILY_V6: {{Priority: linuxTUNRuleStart, Table: linuxTUNTable}}}}
	cfg := tunTestConfig(t, true)
	for range 3 {
		if err := checkLinuxTUNResources(cfg, m); err == nil {
			t.Fatal("restart must not adopt or delete stale-looking rules")
		}
	}
	if len(m.rules[netlink.FAMILY_V6]) != 1 {
		t.Fatal("stale rules removed")
	}
}
