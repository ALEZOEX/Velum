//go:build linux

package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"runtime"
	"strconv"
	"syscall"
	"time"
)

type tunReady struct {
	Error     string
	Interface string
}

func runTUNCommand(args []string) (bool, error) {
	if len(args) == 0 {
		return false, nil
	}
	switch args[0] {
	case "--recover-tun":
		if len(args) != 1 {
			return true, errors.New("usage: velumd --recover-tun")
		}
		return true, recoverTUN()
	case "--tun-supervisor":
		if len(args) != 3 {
			return true, errors.New("invalid internal TUN supervisor arguments")
		}
		return true, superviseTUN(args[1], args[2])
	}
	return false, nil
}
func recoverAllowedTUN(allowed bool) error {
	if !allowed {
		return nil
	}
	return recoverTUN()
}
func setTUNResolved(index int, servers []string) error {
	for _, args := range [][]string{{"domain", strconv.Itoa(index), "~."}, {"default-route", strconv.Itoa(index), "true"}, append([]string{"dns", strconv.Itoa(index)}, servers...)} {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		result, e := exec.CommandContext(ctx, "/usr/bin/resolvectl", args...).CombinedOutput()
		cancel()
		if e != nil {
			return fmt.Errorf("TUN per-link DNS configuration failed: %s: %w", result, e)
		}
	}
	return nil
}
func decodeTUNConfig(path string) (map[string]any, error) {
	b, e := os.ReadFile(path)
	if e != nil {
		return nil, e
	}
	var cfg map[string]any
	if e = json.Unmarshal(b, &cfg); e != nil {
		return nil, e
	}
	in, e := linuxTUNInbound(cfg)
	if e != nil {
		return nil, e
	}
	for _, key := range []string{"iproute2_table_index", "iproute2_rule_index", "file_descriptor", "mtu"} {
		if v, ok := in[key].(float64); ok && v == float64(int(v)) {
			in[key] = int(v)
		}
	}
	for _, key := range []string{"address", "route_exclude_address"} {
		values, e := tunStrings(in[key])
		if e != nil {
			return nil, e
		}
		if values != nil {
			in[key] = values
		}
	}
	return cfg, nil
}
func superviseTUN(core, path string) (result error) {
	// Pdeathsig is tied to the spawning OS thread. Keep that thread alive for
	// the complete core lifetime; the supervisor itself has no Pdeathsig.
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	ready := os.NewFile(3, "ready")
	unixCloseOnExec(3)
	defer ready.Close()
	report := tunReady{}
	defer func() {
		if result != nil {
			report.Error = result.Error()
			_ = json.NewEncoder(ready).Encode(report)
		}
	}()
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	go func() { _, _ = io.Copy(io.Discard, os.Stdin); cancel() }() // EOF also detects SIGKILL of velumd.
	lease, e := acquireTUNLease()
	if e != nil {
		return e
	}
	defer lease.close()
	if e = lease.recover(); e != nil {
		return e
	}
	cfg, e := decodeTUNConfig(path)
	if e != nil {
		return e
	}
	if e = checkTUNWithLease(cfg); e != nil {
		return e
	}
	in, _ := linuxTUNInbound(cfg)
	route := cfg["route"].(map[string]any)
	iface, _ := route["default_interface"].(string)
	endpoint, e := tunPinnedEndpoint(in)
	if e != nil {
		return e
	}
	if iface == "" {
		iface, e = detectOutboundInterface(endpoint.String())
		if e != nil {
			return e
		}
	}
	if e = validateEndpointPhysicalRoute(endpoint, iface); e != nil {
		return e
	}
	route["default_interface"], route["auto_detect_interface"] = iface, false
	b, e := json.Marshal(cfg)
	if e != nil {
		return e
	}
	if e = os.WriteFile(path, b, 0600); e != nil {
		return e
	}
	journal, e := newTUNJournal(lease)
	if e != nil {
		return e
	}
	tun, index, e := createOwnedTUN(in, journal)
	if e != nil {
		return e
	}
	var cmd *exec.Cmd
	var done chan struct{}
	defer func() {
		if stopErr := stopProcess(cmd, done); stopErr != nil {
			tun.Close()
			// The child holds FD4 and its TUN FD. Leave its ownership journal
			// intact for independent recovery after the kernel reaps it.
			result = errors.Join(result, stopErr)
			return
		}
		tun.Close() // Kernel removes only the nonpersistent interface held by this FD.
		if cleanup := lease.recover(); cleanup != nil {
			result = errors.Join(result, fmt.Errorf("TUN cleanup incomplete: %w", cleanup))
		}
	}()
	journal.Objects, e = tunPlan(in, index, journal.Mark)
	if e != nil {
		return e
	}
	sources, e := tunUplinkSources(iface)
	if e != nil {
		return e
	}
	directRules, e := tunDirectReturnRules(cfg, sources, journal.Mark)
	if e != nil {
		return e
	}
	// Transport and direct-return rules precede ordinary application policy.
	transportRules := tunEndpointTransportRules(endpoint, journal.Mark)
	journal.Objects = append(append(transportRules, directRules...), journal.Objects...)
	if e = lease.install(journal, tunMutate); e != nil {
		return e
	}
	if e = ctx.Err(); e != nil {
		return e
	}
	// No local mixed or bridge client can start a core transport before the
	// pinned endpoint rule and all application routes are installed.
	cmd = exec.Command(core, "run", "-c", path)
	cmd.Stdout, cmd.Stderr = os.Stdout, os.Stderr
	cmd.ExtraFiles = []*os.File{tun, lease.lock} // FD4 keeps the lease if the supervisor is killed first.
	configureChild(cmd)
	if e = cmd.Start(); e != nil {
		cmd = nil
		return e
	}
	done = make(chan struct{})
	go func() { _ = cmd.Wait(); close(done) }()
	api := cfg["experimental"].(map[string]any)["clash_api"].(map[string]any)
	if e = awaitCoreAPI(ctx, api["external_controller"].(string), api["secret"].(string), done, nil); e != nil {
		return e
	}
	if e = configureTUNDNS(index, in); e != nil {
		return e
	}
	report.Interface = iface
	if e = json.NewEncoder(ready).Encode(report); e != nil {
		return e
	}
	ready.Close()
	select {
	case <-ctx.Done():
		return nil
	case <-done:
		return errors.New("TUN core exited unexpectedly")
	}
}
func unixCloseOnExec(fd int) { syscall.CloseOnExec(fd) }

func startManagedTUN(core, path string, logs io.Writer) (*exec.Cmd, chan struct{}, io.Closer, string, error) {
	cmd, done, life, iface, err := startManagedTUNContext(context.Background(), core, path, logs)
	if err != nil {
		return nil, nil, nil, "", errors.Join(err, stopProcess(cmd, done))
	}
	return cmd, done, life, iface, nil
}
func startManagedTUNContext(ctx context.Context, core, path string, logs io.Writer) (*exec.Cmd, chan struct{}, io.Closer, string, error) {
	executable, e := os.Executable()
	if e != nil {
		return nil, nil, nil, "", e
	}
	r, w, e := os.Pipe()
	if e != nil {
		return nil, nil, nil, "", e
	}
	defer r.Close()
	cmd := exec.Command(executable, "--tun-supervisor", core, path)
	cmd.ExtraFiles = []*os.File{w}
	// A killed supervisor can leave a stopped core holding inherited log pipes.
	// Bound pipe draining independently of resource ownership (the core keeps FD4).
	cmd.WaitDelay = time.Second
	cmd.Stdout, cmd.Stderr = logs, logs
	life, e := cmd.StdinPipe()
	if e != nil {
		w.Close()
		return nil, nil, nil, "", e
	}
	// Do not configureChild: parent death is handled by EOF independently, so the
	// supervisor can finish cleanup after the parent's Go defers are impossible.
	if e = cmd.Start(); e != nil {
		life.Close()
		w.Close()
		return nil, nil, nil, "", e
	}
	w.Close()
	done := make(chan struct{})
	go func() { _ = cmd.Wait(); close(done) }()
	type reply struct {
		v tunReady
		e error
	}
	replyCh := make(chan reply, 1)
	go func() {
		var v tunReady
		e := json.NewDecoder(io.LimitReader(r, 8192)).Decode(&v)
		replyCh <- reply{v, e}
	}()
	timer := time.NewTimer(15 * time.Second)
	defer timer.Stop()
	select {
	case res := <-replyCh:
		if res.e == nil && res.v.Error == "" {
			return cmd, done, life, res.v.Interface, nil
		}
		if res.v.Error != "" {
			e = errors.New(res.v.Error)
		} else {
			e = fmt.Errorf("TUN supervisor startup failed: %w", res.e)
		}
	case <-ctx.Done():
		e = ctx.Err()
	case <-timer.C:
		e = errors.New("TUN supervisor startup timed out")
	}
	_ = life.Close()
	return cmd, done, nil, "", e
}

func checkTUNWithLease(cfg map[string]any) error {
	h, e := newTUNReader()
	if e != nil {
		return e
	}
	defer h.Close()
	return checkLinuxTUNResources(cfg, h)
}
