//go:build linux

package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"
)

func awaitF11[T any](t *testing.T, pending <-chan T, operation string) T {
	t.Helper()
	select {
	case value := <-pending:
		return value
	case <-time.After(5 * time.Second):
		t.Fatalf("%s did not complete", operation)
		var zero T
		return zero
	}
}

func TestF11InvalidReconnectDoesNotCancelFirstConnect(t *testing.T) {
	started, release := make(chan context.Context, 1), make(chan struct{})
	lookupErr := errors.New("controlled DNS result")
	s := &service{tun: true, interfaceName: "lo", state: "disconnected"}
	s.endpointLookup = func(ctx context.Context, _ string) (endpointAnswer, error) {
		started <- ctx
		select {
		case <-release:
			return endpointAnswer{}, lookupErr
		case <-ctx.Done():
			return endpointAnswer{}, ctx.Err()
		}
	}
	reply := make(chan *httptest.ResponseRecorder, 1)
	go func() { reply <- endpointRequest(s, "/v1/connect", ConnectRequest{URI: endpointTestURI()}) }()
	lookupCtx := awaitF11(t, started, "initial DNS lookup")
	retry := endpointRequest(s, "/v1/reconnect", map[string]any{})
	close(release)
	first := awaitF11(t, reply, "initial connect response")

	if retry.Code < 400 || !strings.Contains(retry.Body.String(), "Нет последнего соединения") {
		t.Fatalf("reconnect without an established profile: status=%d body=%s", retry.Code, retry.Body)
	}
	if !strings.Contains(first.Body.String(), lookupErr.Error()) {
		t.Fatalf("rejected reconnect canceled the accepted connect: status=%d ctx=%v body=%s", first.Code, lookupCtx.Err(), first.Body)
	}
}

func TestF11CoreExitDuringHealthCheckDiscardsSuccess(t *testing.T) {
	started, release := make(chan struct{}), make(chan struct{})
	checkedCore := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		close(started)
		<-release
		_, _ = w.Write([]byte(`{"delay":5}`))
	}))
	defer checkedCore.Close()
	coreDone := make(chan struct{})
	s := &service{
		state: "running", cmd: &exec.Cmd{}, done: coreDone,
		apiAddress: strings.TrimPrefix(checkedCore.URL, "http://"), apiSecret: "check-session",
	}
	reply := make(chan *httptest.ResponseRecorder, 1)
	go func() { reply <- endpointRequest(s, "/v1/check", map[string]any{}) }()
	awaitF11(t, started, "core health request")
	close(coreDone)
	close(release)
	result := awaitF11(t, reply, "health response")
	if result.Code < 400 {
		t.Errorf("check reported success after the core exited: %s", result.Body)
	}
	status := endpointRequest(s, "/v1/status", nil)
	if strings.Contains(status.Body.String(), `"verified":true`) {
		t.Fatalf("stale check marked a dead core verified: %s", status.Body)
	}
}

type f11SlowLifeline struct {
	started chan struct{}
	release chan struct{}
}

func (l *f11SlowLifeline) Close() error {
	close(l.started)
	<-l.release
	return nil
}

func TestF11StatusResponsiveDuringSlowSupervisorStop(t *testing.T) {
	life := &f11SlowLifeline{make(chan struct{}), make(chan struct{})}
	s := &service{state: "running", tun: true, tunActive: true, tunLife: life}
	stop := make(chan *httptest.ResponseRecorder, 1)
	go func() { stop <- endpointRequest(s, "/v1/disconnect", map[string]any{}) }()
	defer func() {
		close(life.release)
		if reply := awaitF11(t, stop, "supervisor stop result"); reply.Code != http.StatusOK {
			t.Errorf("supervisor did not stop after release: %s", reply.Body)
		}
	}()
	awaitF11(t, life.started, "supervisor shutdown")
	status := make(chan *httptest.ResponseRecorder, 1)
	go func() { status <- endpointRequest(s, "/v1/status", nil) }()
	reply := awaitF11(t, status, "status while supervisor was held at a barrier")
	if reply.Code != http.StatusOK || !strings.Contains(reply.Body.String(), `"state":"disconnecting"`) {
		t.Fatalf("status misreported supervisor teardown: %s", reply.Body)
	}
}

func TestF11ShutdownJoinsCanceledHTTPHandlersBeforeRemovingDirectory(t *testing.T) {
	dir := t.TempDir()
	started, canceled, release := make(chan struct{}), make(chan struct{}), make(chan struct{})
	handlerDone := make(chan struct{})
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	runtime := &daemonRuntime{
		svc:      &service{state: "disconnected"},
		dir:      dir,
		listener: listener,
		server: &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			defer close(handlerDone)
			close(started)
			<-r.Context().Done()
			close(canceled)
			<-release
			// A running handler still has access to the daemon's directory.
			if _, err := os.Stat(dir); err != nil {
				t.Error(err)
			}
		})},
	}
	serveDone := make(chan error, 1)
	go func() { serveDone <- runtime.serve(ctx) }()
	client := &http.Client{Timeout: 5 * time.Second}
	defer client.CloseIdleConnections()
	clientDone := make(chan struct{})
	go func() {
		defer close(clientDone)
		if response, err := client.Get("http://" + listener.Addr().String()); err == nil {
			response.Body.Close()
		}
	}()
	awaitF11(t, started, "handler start")
	cancel()
	awaitF11(t, canceled, "handler cancellation")
	select {
	case err := <-serveDone:
		t.Errorf("daemon stopped with a handler still using its directory: %v", err)
		close(release)
		awaitF11(t, handlerDone, "HTTP handler exit")
		awaitF11(t, clientDone, "HTTP client exit")
		return
	case <-time.After(200 * time.Millisecond):
	}
	close(release)
	if err := awaitF11(t, serveDone, "daemon shutdown after handler exit"); err != nil {
		t.Fatal(err)
	}
	awaitF11(t, handlerDone, "HTTP handler exit")
	awaitF11(t, clientDone, "HTTP client exit")
	if _, err := os.Stat(dir); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("runtime directory retained after drain: %v", err)
	}
}

func TestF11ConcurrentConnectsKeepOnlyLatestGeneration(t *testing.T) {
	started := make(chan context.Context, 3)
	release := make(chan struct{})
	lookupErr := errors.New("latest DNS attempt")
	s := &service{tun: true, interfaceName: "lo", state: "disconnected"}
	s.endpointLookup = func(ctx context.Context, _ string) (endpointAnswer, error) {
		started <- ctx
		select {
		case <-release:
			return endpointAnswer{}, lookupErr
		case <-ctx.Done():
			return endpointAnswer{}, ctx.Err()
		}
	}
	var responses []chan *httptest.ResponseRecorder
	for i := 0; i < 3; i++ {
		reply := make(chan *httptest.ResponseRecorder, 1)
		responses = append(responses, reply)
		go func() { reply <- endpointRequest(s, "/v1/connect", ConnectRequest{URI: endpointTestURI()}) }()
		awaitF11(t, started, "DNS for latest generation")
	}
	// All three requests entered the daemon. The final DNS call is still gated.
	for _, reply := range responses[:2] {
		result := awaitF11(t, reply, "superseded connect")
		if result.Code != http.StatusConflict {
			t.Fatalf("superseded connect did not report cancellation: %d %s", result.Code, result.Body)
		}
	}
	close(release)
	last := awaitF11(t, responses[2], "latest connect")
	if last.Code != http.StatusBadRequest || !strings.Contains(last.Body.String(), lookupErr.Error()) {
		t.Fatalf("latest result was lost: %d %s", last.Code, last.Body)
	}
}

func TestF11HTTPClientDisconnectCancelsInFlightPreparation(t *testing.T) {
	started := make(chan struct{})
	canceled := make(chan error, 1)
	s := &service{tun: true, interfaceName: "lo", state: "disconnected", token: "f11-token"}
	s.endpointLookup = func(ctx context.Context, _ string) (endpointAnswer, error) {
		close(started)
		<-ctx.Done()
		canceled <- ctx.Err()
		return endpointAnswer{}, ctx.Err()
	}
	server := httptest.NewServer(http.HandlerFunc(s.handler))
	defer server.Close()
	body, err := json.Marshal(ConnectRequest{URI: endpointTestURI()})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, server.URL+"/v1/connect", strings.NewReader(string(body)))
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Authorization", "Bearer "+s.token)
	clientDone := make(chan error, 1)
	go func() {
		response, err := server.Client().Do(request)
		if response != nil {
			response.Body.Close()
		}
		clientDone <- err
	}()
	awaitF11(t, started, "HTTP connect preparation")
	cancel()
	if err := awaitF11(t, canceled, "DNS cancellation after HTTP peer exit"); !errors.Is(err, context.Canceled) {
		t.Fatalf("resolver shutdown, want cancellation: %v", err)
	}
	if err := awaitF11(t, clientDone, "HTTP client"); !errors.Is(err, context.Canceled) {
		t.Fatalf("client disconnect, want cancellation: %v", err)
	}
	result := endpointRequest(s, "/v1/status", nil)
	if !strings.Contains(result.Body.String(), `"state":"disconnected"`) {
		t.Fatalf("abandoned request changed daemon status: %s", result.Body)
	}
}

func TestF11ShutdownCancelsPendingReconnect(t *testing.T) {
	started, interrupted := make(chan struct{}), make(chan error, 1)
	s := &service{
		tun: true, interfaceName: "lo", state: "running",
		desired: &ConnectRequest{URI: endpointTestURI()},
	}
	s.endpointLookup = func(ctx context.Context, _ string) (endpointAnswer, error) {
		close(started)
		<-ctx.Done()
		interrupted <- ctx.Err()
		return endpointAnswer{}, ctx.Err()
	}
	reconnecting := make(chan *httptest.ResponseRecorder, 1)
	go func() {
		reconnecting <- endpointRequest(s, "/v1/reconnect", map[string]any{})
	}()
	awaitF11(t, started, "reconnect DNS")
	stopped := make(chan error, 1)
	go func() { stopped <- s.shutdown() }()
	if err := awaitF11(t, interrupted, "shutdown cancellation of reconnect"); !errors.Is(err, context.Canceled) {
		t.Fatalf("reconnect canceled with %v", err)
	}
	if err := awaitF11(t, stopped, "shutdown"); err != nil {
		t.Fatal(err)
	}
	if reply := awaitF11(t, reconnecting, "canceled reconnect response"); reply.Code != http.StatusConflict {
		t.Errorf("canceled reconnect returned %d %s", reply.Code, reply.Body)
	}
	status := endpointRequest(s, "/v1/status", nil)
	if !strings.Contains(status.Body.String(), `"state":"disconnected"`) || s.desired != nil {
		t.Fatalf("shutdown retained a reconnect target: %s", status.Body)
	}
}

func TestF11RepeatedDisconnectAndShutdownCloseLifelineOnce(t *testing.T) {
	life := &f11SlowLifeline{make(chan struct{}), make(chan struct{})}
	s := &service{state: "running", tun: true, tunActive: true, tunLife: life}
	disconnect := make(chan *httptest.ResponseRecorder, 1)
	go func() { disconnect <- endpointRequest(s, "/v1/disconnect", map[string]any{}) }()
	awaitF11(t, life.started, "first disconnect")
	shutdown := make(chan error, 2)
	for range 2 {
		go func() { shutdown <- s.shutdown() }()
	}
	close(life.release)
	if reply := awaitF11(t, disconnect, "first disconnect response"); reply.Code != http.StatusOK {
		t.Errorf("first disconnect returned %d %s", reply.Code, reply.Body)
	}
	for range 2 {
		if err := awaitF11(t, shutdown, "overlapping shutdown"); err != nil {
			t.Error(err)
		}
	}
	if err := s.shutdown(); err != nil {
		t.Error(err)
	}
	if reply := endpointRequest(s, "/v1/disconnect", map[string]any{}); reply.Code == http.StatusOK {
		t.Error("shutdown continued accepting commands")
	}
	status := endpointRequest(s, "/v1/status", nil)
	if !strings.Contains(status.Body.String(), `"state":"disconnected"`) || s.tunLife != nil {
		t.Fatalf("repeated stop left an owned lifeline: %s", status.Body)
	}
}

func TestF11SupersededDNSFailureCannotReplaceNewestStatus(t *testing.T) {
	started, firstRelease := make(chan struct{}), make(chan struct{})
	oldErr := errors.New("stale DNS failure")
	newErr := errors.New("latest DNS failure")
	s := &service{tun: true, interfaceName: "lo", state: "disconnected"}
	s.endpointLookup = func(_ context.Context, host string) (endpointAnswer, error) {
		if host == "endpoint.example" {
			close(started)
			<-firstRelease // Simulate a resolver that does not respond to cancellation.
			return endpointAnswer{}, oldErr
		}
		return endpointAnswer{}, newErr
	}
	oldReply := make(chan *httptest.ResponseRecorder, 1)
	go func() { oldReply <- endpointRequest(s, "/v1/connect", ConnectRequest{URI: endpointTestURI()}) }()
	awaitF11(t, started, "stalled DNS lookup")
	latestURI := strings.Replace(endpointTestURI(), "endpoint.example", "next.example", 1)
	newReply := endpointRequest(s, "/v1/connect", ConnectRequest{URI: latestURI})
	close(firstRelease)
	if newReply.Code != http.StatusBadRequest || !strings.Contains(newReply.Body.String(), newErr.Error()) {
		t.Errorf("latest error missing from request response: %d %s", newReply.Code, newReply.Body)
	}
	if reply := awaitF11(t, oldReply, "stale DNS response"); reply.Code != http.StatusConflict {
		t.Errorf("superseded error was accepted: %d %s", reply.Code, reply.Body)
	}
	status := endpointRequest(s, "/v1/status", nil)
	if !strings.Contains(status.Body.String(), newErr.Error()) || strings.Contains(status.Body.String(), oldErr.Error()) {
		t.Fatalf("old DNS result overwrote status: %s", status.Body)
	}
}

func TestF11ShutdownReleasesOwnedLifelineDescriptor(t *testing.T) {
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()
	defer writer.Close()
	s := &service{state: "running", tun: true, tunActive: true, tunLife: writer}
	if err := s.shutdown(); err != nil {
		t.Fatal(err)
	}
	if err := s.shutdown(); err != nil {
		t.Fatal(err)
	}
	if err := reader.SetReadDeadline(time.Now().Add(5 * time.Second)); err != nil {
		t.Fatal(err)
	}
	var discarded [1]byte
	if n, err := reader.Read(discarded[:]); n != 0 || !errors.Is(err, io.EOF) {
		t.Fatalf("supervisor lifeline still retains an open writer: bytes=%d err=%v", n, err)
	}
}

func TestF11ReconnectSupersedesUncommittedReplacement(t *testing.T) {
	current := endpointTestURI()
	candidate := strings.Replace(current, "endpoint.example", "next.example", 1)
	started := make(chan struct{})
	retryErr := errors.New("resolved the committed profile")
	s := &service{
		tun: true, interfaceName: "lo", state: "running",
		desired: &ConnectRequest{URI: current},
	}
	s.endpointLookup = func(ctx context.Context, host string) (endpointAnswer, error) {
		if host == "next.example" {
			close(started)
			<-ctx.Done()
			return endpointAnswer{}, ctx.Err()
		}
		return endpointAnswer{}, retryErr
	}
	replacing := make(chan *httptest.ResponseRecorder, 1)
	go func() { replacing <- endpointRequest(s, "/v1/connect", ConnectRequest{URI: candidate}) }()
	awaitF11(t, started, "replacement DNS")
	retry := endpointRequest(s, "/v1/reconnect", map[string]any{})
	if retry.Code != http.StatusBadRequest || !strings.Contains(retry.Body.String(), retryErr.Error()) {
		t.Fatalf("reconnect did not use the committed profile: %d %s", retry.Code, retry.Body)
	}
	if reply := awaitF11(t, replacing, "superseded replacement"); reply.Code != http.StatusConflict {
		t.Errorf("superseded replacement returned %d %s", reply.Code, reply.Body)
	}
	status := endpointRequest(s, "/v1/status", nil)
	if !strings.Contains(status.Body.String(), `"state":"running"`) {
		t.Fatalf("failed preparation stopped the current profile: %s", status.Body)
	}
}
