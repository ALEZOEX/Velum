//go:build linux

package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/sagernet/netlink"
	"golang.org/x/sys/unix"
)

func runF2Cases(t *testing.T, core, daemon string, uplink *netlink.Dummy, baseline []string, newService func() *service, request func(bool) ConnectRequest) {
	t.Run("wire_roundtrip", func(t *testing.T) {
		objects, e := tunPlan(tunTestConfig(t, true)["inbounds"].([]any)[1].(map[string]any), uplink.Index, 1234567)
		mustF2(t, e)
		for i, o := range objects {
			mustF2(t, tunMutate(o, true))
			actual, e := tunDump(o.Kind, int(o.Wire[0]))
			mustF2(t, e)
			key, e := o.canonical()
			mustF2(t, e)
			found := false
			for _, a := range actual {
				k, e := a.canonical()
				mustF2(t, e)
				if k == key {
					found = true
				}
			}
			if !found {
				t.Fatalf("object %d not matched: %x; %+v", i, o.Wire, actual)
			}
		}
		for i := len(objects) - 1; i >= 0; i-- {
			o := objects[i]
			key, _ := o.canonical()
			current, e := tunDump(o.Kind, int(o.Wire[0]))
			mustF2(t, e)
			for _, a := range current {
				k, _ := a.canonical()
				if k == key {
					mustF2(t, tunMutate(a, false))
				}
			}
		}
		assertF2Snapshot(t, baseline)
	})
	t.Run("normal_repeated_dual_stack", func(t *testing.T) {
		s := newService()
		defer s.stop()
		for i := 0; i < 8; i++ {
			mustF2(t, s.connectRequest(request(i%2 == 0)))
			mustF2(t, s.stop())
			mustF2(t, s.stop())
			assertF2Snapshot(t, baseline)
		}
	})
	t.Run("endpoint_path_before_core_start_rollback", func(t *testing.T) {
		s := newService()
		defer s.stop()
		s.core = filepath.Join(s.dir, "failing-core")
		// Observe the real kernel from the first instruction of "run". Abort
		// before readiness so the supervisor must roll back the entire plan.
		const script = `#!/bin/sh
set -eu
if [ "$1" = check ]; then exit 0; fi
ip -j -4 route get 192.0.2.2 uid 0 > "$3.root"
ip -j -4 route get 192.0.2.2 uid 65534 > "$3.user"
exit 42
`
		mustF2(t, os.WriteFile(s.core, []byte(script), 0700))
		req := request(true)
		req.URI = strings.Replace(req.URI, "192.0.2.1", "192.0.2.2", 1)
		if err := s.connectRequest(req); err == nil {
			t.Fatal("failed core reported a successful connection")
		}
		for suffix, want := range map[string]string{"root": uplink.Name, "user": "velum0"} {
			data, err := os.ReadFile(filepath.Join(s.dir, "config.json."+suffix))
			mustF2(t, err)
			var routes []struct{ Dev string }
			mustF2(t, json.Unmarshal(data, &routes))
			if len(routes) != 1 || routes[0].Dev != want {
				t.Fatalf("packet path for %s at core startup: got %s, want %s", suffix, data, want)
			}
		}
		assertF2Snapshot(t, baseline)
		if _, err := readF2Journal(); !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("failed startup left a journal: %v", err)
		}
	})
	t.Run("concurrent_velum_starts", func(t *testing.T) {
		a, b := newService(), newService()
		defer a.stop()
		defer b.stop()
		gate := make(chan struct{})
		results := make(chan error, 2)
		for _, s := range []*service{a, b} {
			go func() { <-gate; results <- s.connectRequest(request(true)) }()
		}
		close(gate)
		success := 0
		for range 2 {
			if e := <-results; e == nil {
				success++
			}
		}
		if success != 1 {
			t.Fatalf("expected one TUN owner, got %d", success)
		}
		if a.cmd != nil {
			mustF2(t, a.stop())
		}
		if b.cmd != nil {
			mustF2(t, b.stop())
		}
		mustF2(t, a.stop())
		mustF2(t, b.stop())
		assertF2Snapshot(t, baseline)
	})
	t.Run("foreign_rules_preexisting", func(t *testing.T) {
		for _, f := range []int{unix.AF_INET, unix.AF_INET6} {
			r := netlink.NewRule()
			r.Family, r.Priority, r.Table = f, linuxTUNRuleStart, 2022
			mustF2(t, netlink.RuleAdd(r))
		}
		before := f2RoutingSnapshot(t)
		s := newService()
		if e := s.connectRequest(request(true)); e == nil {
			t.Fatal("occupied priority accepted")
		}
		if s.cmd != nil {
			t.Fatal("core launched on conflict")
		}
		assertF2Snapshot(t, before)
	})
	t.Run("foreign_during_session", func(t *testing.T) {
		s := newService()
		defer s.stop()
		mustF2(t, s.connectRequest(request(true)))
		l, e := readF2Journal()
		mustF2(t, e)
		var foreign []tunObject
		for _, o := range l.Objects {
			if o.Kind == "rule" {
				f := tunSetAttr(o, unix.FRA_FWMARK, tunU32(7654321))
				f = tunSetAttr(f, unix.FRA_PROTOCOL, []byte{250})
				mustF2(t, tunMutate(f, true))
				foreign = append(foreign, f)
			}
		}
		for _, prefix := range []string{"198.19.0.0/16", "fd00:19::/64"} {
			r := &netlink.Route{LinkIndex: uplink.Index, Dst: ipNet(prefix), Table: linuxTUNTable, Priority: 91, Protocol: 99}
			mustF2(t, netlink.RouteAdd(r))
		}
		mustF2(t, s.stop())
		after := f2RoutingSnapshot(t)
		// Compare the full foreign snapshot with a baseline obtained by removing
		// only our test-created foreign objects, then restoring those exact objects.
		for _, o := range foreign {
			mustF2(t, tunMutate(o, false))
		}
		for _, prefix := range []string{"198.19.0.0/16", "fd00:19::/64"} {
			mustF2(t, netlink.RouteDel(&netlink.Route{LinkIndex: uplink.Index, Dst: ipNet(prefix), Table: linuxTUNTable, Priority: 91, Protocol: 99}))
		}
		assertF2Snapshot(t, baseline)
		for _, o := range foreign {
			mustF2(t, tunMutate(o, true))
		}
		for _, prefix := range []string{"198.19.0.0/16", "fd00:19::/64"} {
			mustF2(t, netlink.RouteAdd(&netlink.Route{LinkIndex: uplink.Index, Dst: ipNet(prefix), Table: linuxTUNTable, Priority: 91, Protocol: 99}))
		}
		mustF2(t, s.stop())
		assertF2Snapshot(t, after)
	})
	t.Run("partial_rule_failure", func(t *testing.T) {
		lease, tun, j := f2OwnedPlan(t)
		defer lease.close()
		count := 0
		var foreign *tunObject
		e := lease.install(j, func(o tunObject, add bool) error {
			if o.Kind == "rule" {
				count++
				if count == 5 {
					r := tunSetAttr(o, unix.FRA_FWMARK, tunU32(7654321))
					r = tunSetAttr(r, unix.FRA_PROTOCOL, []byte{250})
					mustF2(t, tunMutate(r, true))
					foreign = &r
					return unix.EINVAL
				}
			}
			return tunMutate(o, add)
		})
		if e == nil || foreign == nil {
			t.Fatal("failure injection not reached")
		}
		tun.Close()
		mustF2(t, lease.recover())
		mustF2(t, lease.recover())
		mustF2(t, tunMutate(*foreign, false))
		assertF2Snapshot(t, baseline)
	})
	t.Run("lost_ack_partial_install", func(t *testing.T) {
		lease, tun, j := f2OwnedPlan(t)
		defer lease.close()
		additions := 0
		e := lease.install(j, func(o tunObject, add bool) error {
			if e := tunMutate(o, add); e != nil {
				return e
			}
			additions++
			if additions == 5 {
				return unix.EIO
			} // Add happened; ACK/result was lost.
			return nil
		})
		if e == nil {
			t.Fatal("injected unknown result succeeded")
		}
		tun.Close()
		mustF2(t, lease.recover())
		assertF2Snapshot(t, baseline)
	})
	t.Run("eexist_never_adopts", func(t *testing.T) {
		lease, tun, j := f2OwnedPlan(t)
		defer lease.close()
		var foreign tunObject
		e := lease.install(j, func(o tunObject, add bool) error {
			if o.Kind == "rule" {
				foreign = o
				mustF2(t, tunMutate(o, true)) // Competing privileged creator wins before Add.
				return tunMutate(o, true)
			}
			return tunMutate(o, add)
		})
		if !errors.Is(e, unix.EEXIST) {
			t.Fatalf("expected EEXIST, got %v", e)
		}
		tun.Close()
		before := f2RoutingSnapshot(t)
		if e := lease.recover(); e == nil {
			t.Fatal("unowned pending identity adopted")
		}
		assertF2Snapshot(t, before)
		key, _ := foreign.canonical()
		current, e := tunDump("rule", int(foreign.Wire[0]))
		mustF2(t, e)
		found := false
		for _, o := range current {
			k, _ := o.canonical()
			if k == key {
				found = true
			}
		}
		if !found {
			t.Fatal("foreign resource deleted")
		}
	})
	t.Run("modified_identity_refuses_cleanup", func(t *testing.T) {
		lease, tun, j := f2OwnedPlan(t)
		mustF2(t, lease.install(j, tunMutate))
		var changed tunObject
		for _, o := range j.Objects {
			if o.Kind == "rule" {
				changed = o
				break
			}
		}
		mustF2(t, tunMutate(changed, false))
		changed = tunSetAttr(changed, unix.FRA_IIFNAME, []byte("f2uplink\x00"))
		mustF2(t, tunMutate(changed, true))
		tun.Close()
		before := f2RoutingSnapshot(t)
		if e := lease.recover(); e == nil {
			t.Fatal("modified marked resource was adopted")
		}
		lease.close()
		if e := recoverTUN(); e == nil {
			t.Fatal("conflict lost on independent recovery")
		}
		assertF2Snapshot(t, before)
	})
	t.Run("exclusive_duplicate_rejected", func(t *testing.T) {
		lease, tun, j := f2OwnedPlan(t)
		mustF2(t, lease.install(j, tunMutate))
		var o tunObject
		for _, candidate := range j.Objects {
			if candidate.Kind == "rule" {
				o = candidate
				break
			}
		}
		// Kernel EXCL prevents exact duplicate insertion; a known EEXIST must not
		// expand ownership. Real kernel operation is checked, not mocked away.
		if e := tunMutate(o, true); !errors.Is(e, unix.EEXIST) {
			t.Fatalf("expected kernel duplicate refusal: %v", e)
		}
		tun.Close()
		mustF2(t, lease.recover())
		lease.close()
		assertF2Snapshot(t, baseline)
	})
	t.Run("corrupt_journal_refuses_cleanup", func(t *testing.T) {
		lease, tun, j := f2OwnedPlan(t)
		mustF2(t, lease.install(j, tunMutate))
		tun.Close()
		j.Hash = "corrupt"
		mustF2(t, lease.write(j))
		lease.close()
		before := f2RoutingSnapshot(t)
		s := newService()
		s.tunManaged = true
		if e := s.stop(); e == nil || s.state != "error" {
			t.Fatal("corrupt state reported as restored")
		}
		assertF2Snapshot(t, before)
	})
	t.Run("unmarked_residual_not_adopted", func(t *testing.T) {
		r := netlink.NewRule()
		r.Family, r.Priority, r.Table = unix.AF_INET6, linuxTUNRuleStart, linuxTUNTable
		mustF2(t, netlink.RuleAdd(r))
		before := f2RoutingSnapshot(t)
		mustF2(t, recoverTUN())
		if e := newService().connectRequest(request(true)); e == nil {
			t.Fatal("unmarked old rule adopted")
		}
		assertF2Snapshot(t, before)
	})
	t.Run("core_SIGKILL_reconnect", func(t *testing.T) {
		s := newService()
		defer s.stop()
		mustF2(t, s.connectRequest(request(true)))
		pid := f2CorePID(t, s.cmd.Process.Pid)
		mustF2(t, syscall.Kill(pid, syscall.SIGKILL))
		waitF2(t, func() bool {
			select {
			case <-s.done:
				return true
			default:
				return false
			}
		})
		s.inspectProcess()
		assertF2Snapshot(t, baseline)
		mustF2(t, s.connectRequest(request(true)))
		mustF2(t, s.stop())
		assertF2Snapshot(t, baseline)
	})
	t.Run("guardian_and_core_SIGKILL_independent_recovery", func(t *testing.T) {
		s := newService()
		mustF2(t, s.connectRequest(request(true)))
		pid := f2CorePID(t, s.cmd.Process.Pid)
		mustF2(t, syscall.Kill(pid, syscall.SIGSTOP))
		mustF2(t, s.cmd.Process.Kill())
		<-s.done
		before := f2RoutingSnapshot(t)
		if e := recoverTUN(); e == nil {
			t.Fatal("recovery removed a live core's resources/lease")
		}
		if !reflect.DeepEqual(before, f2RoutingSnapshot(t)) {
			t.Fatal("busy recovery mutated live resources")
		}
		mustF2(t, syscall.Kill(pid, syscall.SIGKILL))
		waitF2(t, func() bool { _, e := netlink.LinkByName("velum0"); return e != nil })
		output, e := exec.Command(daemon, "--recover-tun").CombinedOutput()
		if e != nil {
			t.Fatalf("independent recovery: %s %v", output, e)
		}
		mustF2(t, recoverTUN())
		mustF2(t, s.stop())
		assertF2Snapshot(t, baseline)
		mustF2(t, s.connectRequest(request(false)))
		mustF2(t, s.stop())
		assertF2Snapshot(t, baseline)
	})
	for _, sig := range []syscall.Signal{syscall.SIGTERM, syscall.SIGKILL} {
		t.Run(fmt.Sprintf("daemon_%d", sig), func(t *testing.T) {
			token := strings.Repeat("f2-isolated-", 4)
			file := filepath.Join(t.TempDir(), "token")
			mustF2(t, os.WriteFile(file, []byte(token), 0600))
			cmd := exec.Command(daemon, "--tun", "--core", core, "--interface", "f2uplink", "--token-file", file)
			var logs bytes.Buffer
			cmd.Stdout, cmd.Stderr = &logs, &logs
			mustF2(t, cmd.Start())
			defer func() {
				if cmd.ProcessState == nil {
					cmd.Process.Kill()
					cmd.Wait()
				}
			}()
			client := &http.Client{Transport: &http.Transport{Proxy: nil}, Timeout: time.Second}
			defer client.CloseIdleConnections()
			api := func(path string, body []byte) error {
				method := "GET"
				if body != nil {
					method = "POST"
				}
				req, _ := http.NewRequest(method, "http://127.0.0.1:27841/v1/"+path, bytes.NewReader(body))
				req.Header.Set("Authorization", "Bearer "+token)
				res, e := client.Do(req)
				if e != nil {
					return e
				}
				defer res.Body.Close()
				if res.StatusCode != 200 {
					b, _ := io.ReadAll(res.Body)
					return fmt.Errorf("API %s: %s", res.Status, b)
				}
				return nil
			}
			waitF2(t, func() bool { return api("status", nil) == nil })
			b, e := json.Marshal(request(true))
			mustF2(t, e)
			mustF2(t, api("connect", b))
			mustF2(t, cmd.Process.Signal(sig))
			cmd.Wait()
			waitF2(t, func() bool { return reflect.DeepEqual(f2RoutingSnapshot(t), baseline) })
			mustF2(t, recoverTUN())
			assertF2Snapshot(t, baseline)
			s := newService()
			mustF2(t, s.connectRequest(request(true)))
			mustF2(t, s.stop())
			assertF2Snapshot(t, baseline)
		})
	}
	t.Run("data_plane_dns_ipv4_ipv6", func(t *testing.T) { testF2DataPlane(t, baseline, newService) })
}
func readF2Journal() (*tunJournal, error) {
	ns, e := tunNamespace()
	if e != nil {
		return nil, e
	}
	b, e := os.ReadFile(filepath.Join(tunStateRoot, "net-"+ns, "journal.json"))
	if e != nil {
		return nil, e
	}
	var j tunJournal
	e = json.Unmarshal(b, &j)
	return &j, e
}
func f2OwnedPlan(t *testing.T) (*tunLease, *os.File, *tunJournal) {
	t.Helper()
	lease, e := acquireTUNLease()
	mustF2(t, e)
	mustF2(t, lease.recover())
	cfg := tunTestConfig(t, true)
	mustF2(t, checkTUNWithLease(cfg))
	j, e := newTUNJournal(lease)
	mustF2(t, e)
	in, _ := linuxTUNInbound(cfg)
	tun, index, e := createOwnedTUN(in, j)
	mustF2(t, e)
	j.Objects, e = tunPlan(in, index, j.Mark)
	mustF2(t, e)
	return lease, tun, j
}
func f2CorePID(t *testing.T, parent int) int {
	t.Helper()
	entries, e := filepath.Glob(fmt.Sprintf("/proc/%d/task/*/children", parent))
	mustF2(t, e)
	for _, name := range entries {
		b, _ := os.ReadFile(name)
		for _, pid := range strings.Fields(string(b)) {
			var n int
			fmt.Sscan(pid, &n)
			if n > 0 {
				return n
			}
		}
	}
	t.Fatal("core child PID not found")
	return 0
}
