package main

import (
	"encoding/json"
	"net"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

const validVLESS = "vless://00000000-0000-4000-8000-000000000001@192.0.2.1:443?security=reality&type=tcp&sni=example.com&pbk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&sid=abcd&flow=xtls-rprx-vision#Test"

func TestProfiles(t *testing.T) {
	for _, uri := range []string{validVLESS, "hy2://secret@192.0.2.2:443?sni=example.com&obfs=salamander&obfs-password=test"} {
		if _, e := outbound(uri); e != nil {
			t.Fatal(e)
		}
	}
	for _, uri := range []string{"", "https://example.com", strings.Replace(validVLESS, ":443", ":0", 1), strings.Replace(validVLESS, "#Test", "&insecure=1#Test", 1), strings.Replace(validVLESS, "sid=abcd", "sid=xyz", 1)} {
		if _, e := outbound(uri); e == nil {
			t.Errorf("accepted invalid profile: %q", uri)
		}
	}
}
func TestAuthorizationAndMalformedInput(t *testing.T) {
	s := &service{token: strings.Repeat("x", 64), state: "disconnected"}
	for _, tc := range []struct {
		path, body, token string
		want              int
	}{{"/v1/status", "", "", 401}, {"/v1/status", "", s.token, 200}, {"/v1/connect", `{"uri":"x","core":"/tmp/evil"}`, s.token, 400}, {"/v1/connect", `{"uri":"x"} {}`, s.token, 400}, {"/v1/connect", strings.Repeat("x", 17000), s.token, 400}} {
		method := "GET"
		if tc.body != "" {
			method = "POST"
		}
		r := httptest.NewRequest(method, tc.path, strings.NewReader(tc.body))
		r.Header.Set("Authorization", "Bearer "+tc.token)
		w := httptest.NewRecorder()
		s.handler(w, r)
		if w.Code != tc.want {
			t.Errorf("%s got %d want %d", tc.path, w.Code, tc.want)
		}
	}
}
func TestRealCoreConfig(t *testing.T) {
	core, e := filepath.Abs("../bin/sing-box")
	if e != nil {
		t.Fatal(e)
	}
	if _, e = os.Stat(core); e != nil {
		t.Skip("build pinned sing-box for integration check")
	}
	for _, tun := range []bool{false, true} {
		for _, uri := range []string{validVLESS, "hy2://secret@192.0.2.2:443?sni=example.com"} {
			cfg, e := config(uri, tun, "")
			if e != nil {
				t.Fatal(e)
			}
			if e = applyExclusions(cfg, []string{"example.org", "192.168.0.0/16"}); e != nil {
				t.Fatal(e)
			}
			b, _ := json.Marshal(cfg)
			p := filepath.Join(t.TempDir(), "config.json")
			if e = os.WriteFile(p, b, 0600); e != nil {
				t.Fatal(e)
			}
			if b, e := exec.Command(core, "check", "-c", p).CombinedOutput(); e != nil {
				t.Fatalf("check failed: %s %v", b, e)
			}
		}
	}
}
func TestCoreLifecycle(t *testing.T) {
	core, _ := filepath.Abs("../bin/sing-box")
	if _, e := os.Stat(core); e != nil {
		t.Skip("build pinned sing-box")
	}
	s := &service{core: core, dir: t.TempDir(), state: "disconnected"}
	defer s.stop()
	address, _ := freeAddress()
	_, port, _ := net.SplitHostPort(address)
	number, _ := strconv.Atoi(port)
	if e := s.connectRequest(ConnectRequest{URI: validVLESS, Settings: ConnectionSettings{ProxyPort: number}}); e != nil {
		t.Fatal(e)
	}
	if s.state != "running" {
		t.Fatal(s.state)
	}
	done := s.done
	s.stop()
	if s.state != "disconnected" {
		t.Fatal(s.state)
	}
	select {
	case <-done:
	default:
		t.Fatal("child process remains alive")
	}
}

func TestExclusionValidation(t *testing.T) {
	for _, value := range []string{"localhost", "example.org/path", "bad..org", "192.168.1.0/99"} {
		cfg, e := config(validVLESS, false, "")
		if e != nil {
			t.Fatal(e)
		}
		if applyExclusions(cfg, []string{value}) == nil {
			t.Errorf("accepted %s", value)
		}
	}
}

func TestBuiltCoreVersion(t *testing.T) {
	core, _ := filepath.Abs("../bin/sing-box")
	if _, err := os.Stat(core); err != nil {
		t.Skip("build pinned sing-box")
	}
	output, err := exec.Command(core, "version", "--name").Output()
	if err != nil {
		t.Fatal(err)
	}
	if strings.TrimSpace(string(output)) != "1.12.12" {
		t.Fatalf("core build reports %q, service requires 1.12.12", strings.TrimSpace(string(output)))
	}
}

func TestExplicitInterfaceConfig(t *testing.T) {
	cfg, err := config(validVLESS, false, "lo")
	if err != nil {
		t.Fatal(err)
	}
	core, _ := filepath.Abs("../bin/sing-box")
	if _, err = os.Stat(core); err != nil {
		t.Skip("build pinned sing-box")
	}
	data, _ := json.Marshal(cfg)
	path := filepath.Join(t.TempDir(), "config.json")
	if err = os.WriteFile(path, data, 0600); err != nil {
		t.Fatal(err)
	}
	route := cfg["route"].(map[string]any)
	if route["auto_detect_interface"] != false || route["default_interface"] != "lo" {
		t.Fatal("explicit interface not selected")
	}
	if output, err := exec.Command(core, "check", "-c", path).CombinedOutput(); err != nil {
		t.Fatalf("check failed: %s %v", output, err)
	}
}
