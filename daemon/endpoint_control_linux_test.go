//go:build linux

package main

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"os/exec"
	"strings"
	"testing"
	"time"
)

func endpointRequest(s *service, path string, body any) *httptest.ResponseRecorder {
	data, _ := json.Marshal(body)
	req := httptest.NewRequest("POST", path, strings.NewReader(string(data)))
	if body == nil {
		req = httptest.NewRequest("GET", path, nil)
	}
	req.Header.Set("Authorization", "Bearer "+s.token)
	response := httptest.NewRecorder()
	s.handler(response, req)
	return response
}
func endpointTestURI() string {
	return strings.Replace(validVLESS, "@192.0.2.1:", "@endpoint.example:", 1)
}
func TestEndpointConnectDisconnectCancelsBlockedDNS(t *testing.T) {
	for _, late := range []bool{false, true} {
		name := "cancelled resolver"
		if late {
			name = "late result"
		}
		t.Run(name, func(t *testing.T) {
			started, release := make(chan struct{}), make(chan struct{})
			s := &service{tun: true, interfaceName: "lo", state: "disconnected", token: "unit-token"}
			s.endpointLookup = func(ctx context.Context, _ string) (endpointAnswer, error) {
				close(started)
				if late {
					<-release
					return endpointAnswer{IPs: []netip.Addr{netip.MustParseAddr("127.0.0.1")}, TTL: time.Second}, nil
				}
				<-ctx.Done()
				return endpointAnswer{}, ctx.Err()
			}
			done := make(chan *httptest.ResponseRecorder, 1)
			go func() { done <- endpointRequest(s, "/v1/connect", ConnectRequest{URI: endpointTestURI()}) }()
			<-started
			status := endpointRequest(s, "/v1/status", nil)
			if status.Code != 200 || !strings.Contains(status.Body.String(), "disconnected") {
				t.Fatalf("blocked DNS froze/widened state: %s", status.Body.String())
			}
			response := endpointRequest(s, "/v1/disconnect", map[string]any{})
			if response.Code != 200 {
				t.Fatalf("disconnect blocked by DNS: %s", response.Body.String())
			}
			if late {
				close(release)
			}
			select {
			case response := <-done:
				if response.Code != http.StatusConflict {
					t.Fatalf("stale command accepted: %d %s", response.Code, response.Body.String())
				}
			case <-time.After(time.Second):
				t.Fatal("cancelled DNS command did not finish")
			}
			if s.cmd != nil || s.endpoint != nil || s.desired != nil || s.state != "disconnected" {
				t.Fatalf("late DNS changed final configuration: %+v", s.status())
			}
		})
	}
}
func TestEndpointStatusDoesNotWaitForLifecycle(t *testing.T) {
	s := &service{state: "running", token: "unit-token"}
	s.ensureStatusCache()
	s.mu.Lock()
	done := make(chan *httptest.ResponseRecorder, 1)
	go func() { done <- endpointRequest(s, "/v1/status", nil) }()
	select {
	case response := <-done:
		if response.Code != 200 || !strings.Contains(response.Body.String(), "running") {
			t.Fatal(response.Body.String())
		}
	case <-time.After(time.Second):
		s.mu.Unlock()
		t.Fatal("status waited for lifecycle I/O")
	}
	s.mu.Unlock()
}
func observedEndpoint(t *testing.T) (*service, *endpointPin) {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	signature, e := endpointInterfaceSignature("lo")
	mustF2(t, e)
	pin := &endpointPin{Host: "endpoint.example", IP: netip.MustParseAddr("192.0.2.1"), Answers: []netip.Addr{netip.MustParseAddr("192.0.2.1")}, Interface: "lo", InterfaceSignature: signature, NextDNS: time.Now().Add(-time.Second), ctx: ctx, cancel: cancel}
	s := &service{tun: true, tunActive: true, interfaceName: "lo", endpoint: pin, cmd: &exec.Cmd{}, state: "running", token: "unit-token"}
	s.ensureStatusCache()
	return s, pin
}
func TestEndpointRefreshPreservesLivePinAndProtection(t *testing.T) {
	s, pin := observedEndpoint(t)
	cmd := s.cmd
	calls := 0
	s.endpointLookup = func(context.Context, string) (endpointAnswer, error) {
		calls++
		return endpointAnswer{IPs: []netip.Addr{netip.MustParseAddr("192.0.2.3")}, TTL: time.Second}, nil
	}
	s.observeEndpoint(context.Background())
	if !pin.NeedsReconnect || pin.IP.String() != "192.0.2.1" || s.cmd != cmd || !s.tunActive || s.state != "running" {
		t.Fatalf("refresh replaced/disabled live protection: %+v", s.statusView())
	}
	for range 5 {
		s.observeEndpoint(context.Background())
	}
	if calls != 1 {
		t.Fatalf("DNS polled on statistics ticks instead of expiry: %d", calls)
	}
	response := endpointRequest(s, "/v1/status", nil)
	if !strings.Contains(response.Body.String(), "переподключение") || !strings.Contains(response.Body.String(), `"needsReconnect":true`) {
		t.Fatal(response.Body.String())
	}
}
func TestEndpointDNSFailureAndRecoveryDoNotReleaseTUN(t *testing.T) {
	for _, failure := range []string{"NXDOMAIN", "SERVFAIL", "timeout"} {
		t.Run(failure, func(t *testing.T) {
			s, pin := observedEndpoint(t)
			cmd := s.cmd
			s.endpointLookup = func(context.Context, string) (endpointAnswer, error) { return endpointAnswer{}, errors.New(failure) }
			s.observeEndpoint(context.Background())
			if pin.DNSErrors != 1 || !strings.Contains(pin.Message, failure) || s.cmd != cmd || !s.tunActive {
				t.Fatal("DNS error lost protection or diagnostics")
			}
			pin.NextDNS = time.Now().Add(-time.Second)
			s.endpointLookup = func(context.Context, string) (endpointAnswer, error) {
				return endpointAnswer{IPs: []netip.Addr{pin.IP}, TTL: time.Second}, nil
			}
			s.observeEndpoint(context.Background())
			if pin.DNSErrors != 0 || pin.Message != "" || s.cmd != cmd || !s.tunActive {
				t.Fatal("DNS recovery did not preserve the live session")
			}
		})
	}
}
func TestEndpointAddressSetAndUnsafeAnswers(t *testing.T) {
	s, pin := observedEndpoint(t)
	s.endpointLookup = func(context.Context, string) (endpointAnswer, error) {
		return endpointAnswer{IPs: []netip.Addr{netip.MustParseAddr("2001:db8::2"), pin.IP, netip.MustParseAddr("192.0.2.2")}, TTL: time.Second}, nil
	}
	s.observeEndpoint(context.Background())
	if pin.NeedsReconnect {
		t.Fatal("round-robin set invalidated a still-present pin")
	}
	pin.NextDNS = time.Now().Add(-time.Second)
	s.endpointLookup = func(context.Context, string) (endpointAnswer, error) {
		return endpointAnswer{IPs: []netip.Addr{netip.MustParseAddr("172.28.0.2")}, TTL: time.Second}, nil
	}
	s.observeEndpoint(context.Background())
	if pin.IP.String() != "192.0.2.1" || pin.DNSErrors != 1 || !s.tunActive {
		t.Fatal("unsafe answer was adopted")
	}
}
func TestEndpointLiteralSkipsDNSAndInterfaceChangeRetainsTUN(t *testing.T) {
	s, pin := observedEndpoint(t)
	pin.Host = pin.IP.String()
	pin.NextDNS = time.Time{}
	s.endpointLookup = func(context.Context, string) (endpointAnswer, error) {
		t.Error("literal endpoint was resolved")
		return endpointAnswer{}, nil
	}
	s.observeEndpoint(context.Background())
	pin.InterfaceSignature = "changed"
	s.observeEndpoint(context.Background())
	if !pin.NeedsReconnect || !s.tunActive || s.cmd == nil {
		t.Fatal("interface change silently removed protection")
	}
}
func TestEndpointLateObservationCannotAffectNewSession(t *testing.T) {
	s, pin := observedEndpoint(t)
	started, release, done := make(chan struct{}), make(chan struct{}), make(chan struct{})
	s.endpointLookup = func(context.Context, string) (endpointAnswer, error) {
		close(started)
		<-release
		return endpointAnswer{IPs: []netip.Addr{netip.MustParseAddr("192.0.2.9")}, TTL: time.Second}, nil
	}
	go func() { defer close(done); s.observeEndpoint(context.Background()) }()
	<-started
	s.mu.Lock()
	pin.cancel()
	s.endpoint = nil
	s.cmd = nil
	s.state = "disconnected"
	s.publishStatusLocked()
	s.mu.Unlock()
	close(release)
	<-done
	if s.state != "disconnected" || s.endpoint != nil || pin.NeedsReconnect {
		t.Fatal("late observation overwrote the newer command")
	}
}

func TestEndpointManualCommandTakesPriorityOverCrashRetry(t *testing.T) {
	s := &service{state: "disconnected"}
	pending, epoch, finish := s.beginControl(context.Background())
	defer finish()
	s.automaticReconnect(context.Background(), epoch, ConnectRequest{URI: "bad URI"}, 1)
	if s.reconnectAttempts != 0 || s.state != "disconnected" {
		t.Errorf("crash retry superseded a manual command: %v", s.statusView())
	}
	_, _, finishDisconnect := s.beginControl(context.Background())
	defer finishDisconnect()
	if pending.Err() == nil {
		t.Fatal("Disconnect did not cancel the pending manual command")
	}
}

func TestEndpointCancelledCandidateKeepsExistingConnection(t *testing.T) {
	started, release := make(chan struct{}), make(chan struct{})
	oldCore := &exec.Cmd{}
	oldDone := make(chan struct{})
	close(oldDone)
	s := &service{dir: t.TempDir(), core: "/usr/bin/true", tun: true, interfaceName: "lo", cmd: oldCore, done: oldDone, state: "running"}
	s.tunPreflight = func(map[string]any) error {
		select {
		case <-started:
			return errors.New("reached second preflight after cancellation")
		default:
		}
		close(started)
		<-release
		return nil
	}
	ctx, epoch, finish := s.beginControl(context.Background())
	defer finish()
	done := make(chan error, 1)
	go func() { done <- s.controlledConnect(ctx, epoch, ConnectRequest{URI: validVLESS}) }()
	select {
	case <-started:
	case err := <-done:
		t.Fatalf("preflight was not reached: %v", err)
	case <-time.After(2 * time.Second):
		t.Fatal("preflight did not start")
	}
	_, _, finishNext := s.beginControl(context.Background())
	defer finishNext()
	close(release)
	if !errors.Is(<-done, context.Canceled) || s.cmd != oldCore || s.state != "running" {
		t.Fatalf("superseded candidate tore down original connection: %v", s.statusView())
	}
}

func TestEndpointStaleHealthCheckCannotBlockDisconnectOrVerifyNewSession(t *testing.T) {
	started, release := make(chan struct{}), make(chan struct{})
	api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		close(started)
		<-release
		_, _ = w.Write([]byte(`{"delay":5}`))
	}))
	defer api.Close()
	s := &service{state: "running", apiAddress: strings.TrimPrefix(api.URL, "http://"), apiSecret: "session-one"}
	check := make(chan *httptest.ResponseRecorder, 1)
	go func() { check <- endpointRequest(s, "/v1/check", map[string]any{}) }()
	<-started
	disconnect := make(chan *httptest.ResponseRecorder, 1)
	go func() { disconnect <- endpointRequest(s, "/v1/disconnect", map[string]any{}) }()
	select {
	case response := <-disconnect:
		if response.Code != 200 {
			t.Error(response.Body.String())
		}
	case <-time.After(time.Second):
		close(release)
		<-check
		<-disconnect
		t.Fatal("slow health check blocked disconnect")
	}
	close(release)
	if response := <-check; response.Code != http.StatusConflict || s.verified || s.state != "disconnected" || s.lastError != "" {
		t.Fatalf("stale health check modified state: %d %+v", response.Code, s.statusView())
	}
}

func TestEndpointReconnectPlansNextAdvertisedAddress(t *testing.T) {
	s, live := observedEndpoint(t)
	cmd := s.cmd
	other := netip.MustParseAddr("192.0.2.2")
	s.endpointLookup = func(context.Context, string) (endpointAnswer, error) {
		return endpointAnswer{IPs: []netip.Addr{other, live.IP}, TTL: time.Minute}, nil
	}
	plan, err := s.prepareEndpoint(context.Background(), ConnectRequest{URI: endpointTestURI()})
	if err != nil {
		t.Fatal(err)
	}
	defer plan.cancel()
	if plan.IP != other || s.endpoint != live || s.cmd != cmd || !s.tunActive {
		t.Fatalf("planning replaced live transport or retained its IP: %v", plan.status())
	}
}

func TestEndpointPinReturnsBeforeReconnect(t *testing.T) {
	s, live := observedEndpoint(t)
	cmd := s.cmd
	other := netip.MustParseAddr("192.0.2.3")
	answers := []netip.Addr{other}
	s.endpointLookup = func(context.Context, string) (endpointAnswer, error) {
		return endpointAnswer{IPs: answers, TTL: time.Minute}, nil
	}
	s.observeEndpoint(context.Background())
	if !live.NeedsReconnect {
		t.Fatal("missing reconnect indication when IP vanished")
	}
	answers = append(answers, live.IP)
	live.NextDNS = time.Now().Add(-time.Second)
	s.observeEndpoint(context.Background())
	if live.NeedsReconnect || live.Message != "" || s.endpoint != live || s.cmd != cmd || !s.tunActive {
		t.Fatalf("returning pinned IP left stale error or replaced transport: %v", s.statusView())
	}
}

type endpointLifeline func() error

func (f endpointLifeline) Close() error { return f() }

func TestEndpointStopWaitsForXrayBeforeReleasingOwnedRoutes(t *testing.T) {
	cmd := exec.Command("sleep", "30")
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	done := make(chan struct{})
	go func() { _ = cmd.Wait(); close(done) }()
	t.Cleanup(func() { _ = cmd.Process.Kill(); <-done })
	released := false
	s := &service{xrayCmd: cmd, xrayDone: done, tunLife: endpointLifeline(func() error {
		select {
		case <-done:
			released = true
		default:
			t.Error("live Xray transport lost its owned route")
		}
		return nil
	})}
	s.stopCore()
	if !released || s.xrayCmd != nil {
		t.Fatal("stop did not reap Xray before route cleanup")
	}
}
