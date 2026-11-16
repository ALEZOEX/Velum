//go:build linux

package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"reflect"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/sagernet/netlink"
	"golang.org/x/sys/unix"
)

func TestMain(m *testing.M) {
	if handled, err := runTUNCommand(os.Args[1:]); handled {
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		os.Exit(0)
	}
	os.Exit(m.Run())
}

// Invoked only by scripts/test-linux-tun-ownership.sh. Ordinary go test skips
// this suite before any network mutation. Never weaken the namespace guards.
func TestF2NetworkNamespace(t *testing.T) {
	host := os.Getenv("VELUM_F2_HOST_NETNS")
	if host == "" {
		t.Skip("requires isolated namespace wrapper")
	}
	self, err := os.Readlink("/proc/self/ns/net")
	if err != nil || self == host {
		t.Fatalf("refusing non-isolated network namespace: %q / %q: %v", self, host, err)
	}
	links, err := netlink.LinkList()
	if err != nil || len(links) != 1 || links[0].Attrs().Name != "lo" {
		t.Fatalf("refusing nonempty namespace: %v %v", links, err)
	}
	core := os.Getenv("VELUM_F2_CORE")
	daemon := os.Getenv("VELUM_F2_DAEMON")
	version, err := exec.Command(core, "version").Output()
	if err != nil || !strings.Contains(string(version), "sing-box version 1.12.12\n") {
		t.Fatalf("pinned core required: %s %v", version, err)
	}
	mustF2(t, netlink.LinkSetUp(links[0]))
	uplink := &netlink.Dummy{LinkAttrs: netlink.LinkAttrs{Name: "f2uplink"}}
	mustF2(t, netlink.LinkAdd(uplink))
	mustF2(t, netlink.LinkSetUp(uplink))
	for _, value := range []string{"192.0.2.1/24", "fd00:2::1/64"} {
		addr, err := netlink.ParseAddr(value)
		mustF2(t, err)
		addr.Flags = unix.IFA_F_NODAD
		mustF2(t, netlink.AddrAdd(uplink, addr))
	}
	for _, prefix := range []string{"0.0.0.0/0", "::/0"} {
		mustF2(t, netlink.RouteAdd(&netlink.Route{LinkIndex: uplink.Index, Dst: ipNet(prefix), Table: 254}))
	}
	// Sentinels model another sing-box VPN and must survive every case.
	for _, family := range []int{netlink.FAMILY_V4, netlink.FAMILY_V6} {
		rule := netlink.NewRule()
		rule.Family, rule.Priority, rule.Table = family, 9000, 2022
		mustF2(t, netlink.RuleAdd(rule))
	}
	for _, prefix := range []string{"198.51.100.0/24", "fd00:51::/64"} {
		mustF2(t, netlink.RouteAdd(&netlink.Route{LinkIndex: uplink.Index, Dst: ipNet(prefix), Table: 2022}))
	}
	baseline := f2RoutingSnapshot(t)
	newService := func() *service {
		return &service{core: core, dir: t.TempDir(), interfaceName: "f2uplink", tun: true, state: "disconnected"}
	}
	request := func(ipv6 bool) ConnectRequest {
		return ConnectRequest{URI: validVLESS, Settings: ConnectionSettings{Mode: "tun", IPv6: &ipv6}}
	}

	runF2Cases(t, core, daemon, uplink, baseline, newService, request)
}

func mustF2(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}
func waitF2(t *testing.T, check func() bool) {
	t.Helper()
	deadline := time.Now().Add(8 * time.Second)
	for time.Now().Before(deadline) {
		if check() {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal("isolated kernel/process operation timed out")
}
func f2RoutingSnapshot(t *testing.T) []string {
	t.Helper()
	var result []string
	// ip preserves rule actions/protocols and route metrics that this pinned
	// netlink package's decoded Rule/String representation omits.
	for _, family := range []string{"-4", "-6"} {
		for _, kind := range []string{"rule", "route"} {
			args := []string{"-j", "-N", family, kind, "show"}
			if kind == "route" {
				args = append(args, "table", "all")
			}
			output, err := exec.Command("ip", args...).CombinedOutput()
			if err != nil {
				t.Fatalf("snapshot failed: %s %v", output, err)
			}
			var entries []map[string]any
			mustF2(t, json.Unmarshal(output, &entries))
			for _, entry := range entries {
				data, err := json.Marshal(entry)
				mustF2(t, err)
				result = append(result, fmt.Sprintf("%s/%s/%s", kind, family, data))
			}
		}
	}
	sort.Strings(result)
	return result
}
func assertF2Snapshot(t *testing.T, expected []string) {
	t.Helper()
	actual := f2RoutingSnapshot(t)
	if !reflect.DeepEqual(expected, actual) {
		t.Fatalf("routing changed:\nwant %v\ngot %v", expected, actual)
	}
	if _, err := netlink.LinkByName("velum0"); err == nil {
		t.Fatal("TUN interface leaked")
	}
}
