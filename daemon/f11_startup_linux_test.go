//go:build linux

package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func startupFixture(t *testing.T) *service {
	t.Helper()
	dir := t.TempDir()
	core := filepath.Join(dir, "fixture")
	// exec gives the process supervisor one PID to signal and reap.
	if err := os.WriteFile(core, []byte("#!/bin/sh\ncase \"$1\" in\ncheck) exit 0 ;;\nrun) exec /usr/bin/sleep 60 ;;\n*) exit 2 ;;\nesac\n"), 0700); err != nil {
		t.Fatal(err)
	}
	return &service{dir: dir, core: core, state: "disconnected"}
}

func TestF11DisconnectDuringCoreStartupReapsChild(t *testing.T) {
	s := startupFixture(t)
	started := make(chan (<-chan struct{}), 1)
	s.waitForStartup = func(ctx context.Context, coreDone, _ <-chan struct{}) error {
		started <- coreDone
		<-ctx.Done()
		return ctx.Err()
	}
	done := make(chan *httptest.ResponseRecorder, 1)
	go func() { done <- endpointRequest(s, "/v1/connect", ConnectRequest{URI: validVLESS}) }()
	childDone := awaitF11(t, started, "start of fake sing-box")
	status := endpointRequest(s, "/v1/status", nil)
	if !strings.Contains(status.Body.String(), `"state":"connecting"`) {
		t.Errorf("starting child published as running: %s", status.Body)
	}
	stop := endpointRequest(s, "/v1/disconnect", map[string]any{})
	if stop.Code != http.StatusOK || !strings.Contains(stop.Body.String(), `"state":"disconnected"`) {
		t.Fatalf("disconnect returned %d: %s", stop.Code, stop.Body)
	}
	awaitF11(t, childDone, "system wait for fake sing-box")
	reply := awaitF11(t, done, "superseded startup")
	if reply.Code != http.StatusConflict {
		t.Fatalf("startup was not canceled: %s", reply.Body)
	}
	if err := s.shutdown(); err != nil {
		t.Fatal(err)
	}
}

func TestF11OldCoreDiesDuringCandidatePreparation(t *testing.T) {
	s := startupFixture(t)
	died := make(chan struct{})
	s.cmd, s.done, s.state = &exec.Cmd{}, died, "running"
	started, release := make(chan struct{}), make(chan struct{})
	// Hold validation of a Linux TUN candidate while the previous core exits,
	// then refuse the candidate before it can touch real networking.
	s.tun, s.interfaceName = true, "lo"
	s.tunPreflight = func(map[string]any) error {
		close(started)
		<-release
		return context.DeadlineExceeded
	}
	reply := make(chan int, 1)
	go func() {
		result := endpointRequest(s, "/v1/connect", ConnectRequest{URI: validVLESS})
		reply <- result.Code
	}()
	awaitF11(t, started, "candidate validation")
	close(died)
	inspected := make(chan struct{})
	go func() { defer close(inspected); s.inspectProcess() }()
	awaitF11(t, inspected, "monitor during candidate validation")
	close(release)
	if status := awaitF11(t, reply, "failed candidate"); status != http.StatusBadRequest {
		t.Fatalf("invalid candidate HTTP status %d", status)
	}
	status := endpointRequest(s, "/v1/status", nil)
	if strings.Contains(status.Body.String(), `"state":"running"`) {
		t.Fatalf("failed preparation restored a dead core as running: %s", status.Body)
	}
	s.inspectProcess()
	if err := s.shutdown(); err != nil {
		t.Fatal(err)
	}
}
