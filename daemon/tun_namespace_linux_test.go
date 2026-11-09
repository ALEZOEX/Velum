//go:build linux

package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/sagernet/netlink"
	"golang.org/x/sys/unix"
)

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

	t.Run("free_start_disconnect_both_families", func(t *testing.T) {
		for _, ipv6 := range []bool{true, false} {
			s := newService()
			t.Cleanup(s.stop)
			mustF2(t, s.connectRequest(request(ipv6)))
			if _, err := netlink.LinkByName("velum0"); err != nil {
				t.Fatal(err)
			}
			// Replacing a live owned TUN must wait for its previous core to
			// finish cleanup before inspecting resources for the new start.
			mustF2(t, s.connectRequest(request(ipv6)))
			for _, family := range []int{netlink.FAMILY_V4, netlink.FAMILY_V6} {
				rules, err := netlink.RuleList(family)
				mustF2(t, err)
				found := false
				for _, rule := range rules {
					if inTUNRuleRange(rule.Priority) {
						found = true
					}
				}
				if !found {
					t.Fatalf("missing own policy rules for %s (IPv6 enabled=%v)", familyName(family), ipv6)
				}
			}
			s.stop()
			s.stop()
			assertF2Snapshot(t, baseline)
		}
	})
	t.Run("occupied_resources_never_launch_core", func(t *testing.T) {
		for _, family := range []int{netlink.FAMILY_V4, netlink.FAMILY_V6} {
			for _, tableOnly := range []bool{false, true} {
				var remove func()
				if tableOnly {
					prefix := "203.0.113.0/24"
					if family == netlink.FAMILY_V6 {
						prefix = "fd00:113::/64"
					}
					route := &netlink.Route{LinkIndex: uplink.Index, Dst: ipNet(prefix), Table: linuxTUNTable}
					mustF2(t, netlink.RouteAdd(route))
					remove = func() { mustF2(t, netlink.RouteDel(route)) }
				} else {
					rule := netlink.NewRule()
					rule.Family, rule.Priority, rule.Table = family, linuxTUNRuleEnd, 2022
					mustF2(t, netlink.RuleAdd(rule))
					remove = func() { mustF2(t, netlink.RuleDel(rule)) }
				}
				before := f2RoutingSnapshot(t)
				s := newService()
				err := s.connectRequest(request(true))
				if err == nil || !strings.Contains(err.Error(), "TUN не запущен") {
					t.Fatalf("occupied resources accepted: %v", err)
				}
				s.stop()
				s.stop()
				assertF2Snapshot(t, before)
				remove()
			}
		}
		assertF2Snapshot(t, baseline)
	})
	t.Run("partial_start_rollback", func(t *testing.T) {
		busy, err := net.Listen("tcp4", "127.0.0.1:0")
		mustF2(t, err)
		defer busy.Close()
		port := busy.Addr().(*net.TCPAddr).Port
		cfg := tunTestConfig(t, true)
		cfg["route"].(map[string]any)["default_interface"] = "f2uplink"
		cfg["route"].(map[string]any)["auto_detect_interface"] = false
		// The first mixed and TUN interfaces initialize, then a subsequent
		// inbound fails to bind. No host or external traffic is involved.
		cfg["inbounds"] = append(cfg["inbounds"].([]any), map[string]any{"type": "mixed", "tag": "fail", "listen": "127.0.0.1", "listen_port": port})
		mustF2(t, checkTUNResources(cfg))
		data, err := json.Marshal(cfg)
		mustF2(t, err)
		path := filepath.Join(t.TempDir(), "partial.json")
		mustF2(t, os.WriteFile(path, data, 0600))
		output, err := exec.Command(core, "run", "-c", path).CombinedOutput()
		if err == nil || !strings.Contains(string(output), "address already in use") || !strings.Contains(string(output), "velum0") {
			t.Fatalf("partial TUN startup not reached: %s %v", output, err)
		}
		assertF2Snapshot(t, baseline)
	})
	t.Run("repeated_disconnect_does_not_clean_new_foreign_rule", func(t *testing.T) {
		s := newService()
		t.Cleanup(s.stop)
		mustF2(t, s.connectRequest(request(true)))
		s.stop()
		rule := netlink.NewRule()
		rule.Family, rule.Priority, rule.Table = netlink.FAMILY_V6, linuxTUNRuleStart, 2022
		mustF2(t, netlink.RuleAdd(rule))
		defer func() { mustF2(t, netlink.RuleDel(rule)) }()
		before := f2RoutingSnapshot(t)
		s.stop()
		s.stop()
		assertF2Snapshot(t, before)
	})
	for _, signal := range []syscall.Signal{syscall.SIGTERM, syscall.SIGKILL} {
		t.Run(fmt.Sprintf("velumd_%s", signal), func(t *testing.T) {
			dir := t.TempDir()
			token := strings.Repeat("f2-isolated-", 4)
			tokenPath := filepath.Join(dir, "token")
			mustF2(t, os.WriteFile(tokenPath, []byte(token), 0600))
			cmd := exec.Command(daemon, "--tun", "--interface", "f2uplink", "--core", core, "--token-file", tokenPath)
			var log bytes.Buffer
			cmd.Stdout, cmd.Stderr = &log, &log
			mustF2(t, cmd.Start())
			defer func() { _ = cmd.Process.Kill(); _ = cmd.Wait() }()
			transport := &http.Transport{Proxy: nil}
			defer transport.CloseIdleConnections()
			client := &http.Client{Transport: transport, Timeout: time.Second}
			api := func(path string, body io.Reader) error {
				method := "GET"
				if body != nil {
					method = "POST"
				}
				req, err := http.NewRequest(method, "http://127.0.0.1:27841/v1/"+path, body)
				if err != nil {
					return err
				}
				req.Header.Set("Authorization", "Bearer "+token)
				res, err := client.Do(req)
				if err != nil {
					return err
				}
				defer res.Body.Close()
				if res.StatusCode != 200 {
					data, _ := io.ReadAll(res.Body)
					return fmt.Errorf("%s: %s", res.Status, data)
				}
				return nil
			}
			waitF2(t, func() bool { return api("status", nil) == nil })
			data, err := json.Marshal(request(true))
			mustF2(t, err)
			mustF2(t, api("connect", bytes.NewReader(data)))
			mustF2(t, cmd.Process.Signal(signal))
			_ = cmd.Wait()
			if signal == syscall.SIGTERM {
				waitF2(t, func() bool { return reflect.DeepEqual(f2RoutingSnapshot(t), baseline) })
				return
			}
			// Pdeathsig requests child cleanup but cannot guarantee it. Accept
			// residual own-range rules only; all foreign resources must survive.
			waitF2(t, func() bool { _, err := netlink.LinkByName("velum0"); return err != nil })
			after := f2RoutingSnapshot(t)
			foreign := make([]string, 0, len(after))
			for _, entry := range after {
				parts := strings.SplitN(entry, "/", 3)
				if parts[0] == "rule" {
					var rule map[string]any
					mustF2(t, json.Unmarshal([]byte(parts[2]), &rule))
					priority, _ := rule["priority"].(float64)
					if inTUNRuleRange(int(priority)) {
						continue
					}
				}
				foreign = append(foreign, entry)
			}
			if !reflect.DeepEqual(foreign, baseline) {
				t.Fatalf("foreign routing changed after daemon death: %v", after)
			}
			if !reflect.DeepEqual(after, baseline) {
				err := newService().connectRequest(request(true))
				if err == nil || !strings.Contains(err.Error(), "policy rule") {
					t.Fatalf("restart must refuse residual rules: %v", err)
				}
				assertF2Snapshot(t, after)
				t.Log("SIGKILL velumd left policy rules; restart refused them without deleting foreign resources")
			} else {
				t.Log("Pdeathsig child cleanup completed in this run")
			}
		})
	}
	t.Run("core_SIGKILL_leaves_rules_restart_refuses", func(t *testing.T) {
		s := newService()
		t.Cleanup(s.stop)
		mustF2(t, s.connectRequest(request(true)))
		mustF2(t, s.cmd.Process.Kill())
		<-s.done
		s.inspectProcess()
		if _, err := netlink.LinkByName("velum0"); err == nil {
			t.Fatal("kernel did not remove nonpersistent TUN")
		}
		stale := f2RoutingSnapshot(t)
		if reflect.DeepEqual(stale, baseline) {
			t.Fatal("expected unowned residual policy rules after SIGKILL")
		}
		if err := s.connectRequest(request(true)); err == nil || !strings.Contains(err.Error(), "policy rule") {
			t.Fatalf("restart adopted stale rules: %v", err)
		}
		assertF2Snapshot(t, stale)
	})
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
