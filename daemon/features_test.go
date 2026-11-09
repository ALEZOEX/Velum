package main

import (
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func checkCoreConfig(t *testing.T, cfg map[string]any) {
	t.Helper()
	core, _ := filepath.Abs("../bin/sing-box")
	if _, e := os.Stat(core); e != nil {
		t.Skip("build pinned core")
	}
	data, _ := json.Marshal(cfg)
	p := filepath.Join(t.TempDir(), "config.json")
	if e := os.WriteFile(p, data, 0600); e != nil {
		t.Fatal(e)
	}
	if output, e := exec.Command(core, "check", "-c", p).CombinedOutput(); e != nil {
		t.Fatalf("config check: %s %v", output, e)
	}
}
func TestSupportedProtocolConfigs(t *testing.T) {
	vmess := `{"v":"2","add":"192.0.2.1","port":"443","id":"00000000-0000-4000-8000-000000000001","net":"ws","path":"/socket","host":"example.com","tls":"tls","sni":"example.com"}`
	for _, uri := range []string{
		"vless://00000000-0000-4000-8000-000000000001@192.0.2.1:443?security=tls&type=ws&sni=example.com&host=example.com&path=%2Fsocket",
		"vless://00000000-0000-4000-8000-000000000001@192.0.2.1:443?security=tls&type=grpc&sni=example.com&serviceName=grpc",
		"vmess://" + base64.StdEncoding.EncodeToString([]byte(vmess)), "trojan://test-password@192.0.2.1:443?sni=example.com&type=tcp",
		"ss://" + base64.RawStdEncoding.EncodeToString([]byte("aes-128-gcm:test-password")) + "@192.0.2.1:443",
		"ss://" + base64.RawStdEncoding.EncodeToString([]byte("aes-128-gcm:test-password@192.0.2.1:443")),
		"socks5://user:password@192.0.2.1:1080", "socks5://192.0.2.1:1080", "http://user:password@192.0.2.1:8080", "https://user:password@192.0.2.1:8443"} {
		cfg, e := buildConfig(uri, false, "", ConnectionSettings{})
		if e != nil {
			t.Fatal(e)
		}
		checkCoreConfig(t, cfg)
	}
}
func TestRoutingDNSAndFragmentation(t *testing.T) {
	cfg, e := buildConfig(validVLESS, true, "", ConnectionSettings{Fragment: true, MTU: 1500, DNS: "https://1.1.1.1/dns-query", DirectDNS: "udp://9.9.9.9", RouteMode: "rules", Rules: []RouteRule{{"block", "domain", "ads.example.com"}, {"direct", "cidr", "10.0.0.0/8"}, {"proxy", "process", "browser"}, {"direct", "domain", "example.org"}}})
	if e != nil {
		t.Fatal(e)
	}
	checkCoreConfig(t, cfg)
}
func TestSettingsRejectUnsafeOrInvalidValues(t *testing.T) {
	for _, s := range []ConnectionSettings{{Mode: "tun"}, {MTU: 10}, {ProxyPort: 53}, {ProxyPort: 65536}, {RouteMode: "whatever"}, {Interface: "not-a-valid-interface"}} {
		if s.validate(false) == nil {
			t.Fatal("invalid settings accepted")
		}
	}
	for _, v := range []string{"file:///etc/passwd", "https://user:pass@1.1.1.1/dns-query", "https://1.1.1.1/dns-query?secret=abc", "exec://127.0.0.1"} {
		if _, e := dnsServer(v, "remote", "proxy"); e == nil {
			t.Fatal("invalid DNS accepted")
		}
	}
}
func TestLogSanitizationAndBound(t *testing.T) {
	var l logBuffer
	l.setSecrets([]string{"secret-password", "secret-public-key"})
	_, _ = l.Write([]byte("\x1b[31mERROR\x1b[0m secret-password secret-public-key vless://sensitive@server\n"))
	for _, v := range l.entries() {
		if strings.Contains(v.Message, "secret-") || strings.Contains(v.Message, "vless://") || strings.Contains(v.Message, "\x1b") {
			t.Fatal("secret leaked")
		}
	}
	for i := 0; i < 350; i++ {
		l.add("info", "test")
	}
	if len(l.entries()) != 300 {
		t.Fatal("logs unbounded")
	}
}
func TestHealthAndTrafficViaAuthenticatedCoreAPI(t *testing.T) {
	api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer private-test-token" {
			w.WriteHeader(401)
			return
		}
		switch r.URL.Path {
		case "/connections":
			_ = json.NewEncoder(w).Encode(map[string]int64{"uploadTotal": 120, "downloadTotal": 300})
		case "/proxies/proxy/delay":
			if r.URL.Query().Get("url") != "https://example.com" {
				t.Error("health target changed")
			}
			_ = json.NewEncoder(w).Encode(map[string]int64{"delay": 37})
		default:
			w.WriteHeader(404)
		}
	}))
	defer api.Close()
	s := &service{state: "running", apiAddress: strings.TrimPrefix(api.URL, "http://"), apiSecret: "private-test-token"}
	if e := s.check(); e != nil {
		t.Fatal(e)
	}
	if !s.verified || s.latencyMs == nil || *s.latencyMs != 37 {
		t.Fatal("health not recorded")
	}
	up, down := int64(100), int64(200)
	s.uploadTotal = &up
	s.downloadTotal = &down
	s.sampleAt = time.Now().Add(-time.Second)
	s.refreshStats()
	if s.uploadTotal == nil || *s.uploadTotal != 120 || s.downloadTotal == nil || *s.downloadTotal != 300 || s.uploadRate == nil || *s.uploadRate < 15 {
		t.Fatal("counters not sampled")
	}
}

func TestTunInboundConfigValidation(t *testing.T) {
	uri := "vless://00000000-0000-4000-8000-000000000001@192.0.2.1:443?security=reality&sni=example.com&pbk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&sid=abcd"
	cfg, err := buildConfig(uri, true, "", ConnectionSettings{})
	if err != nil {
		t.Fatal(err)
	}
	inbounds, ok := cfg["inbounds"].([]any)
	if !ok || len(inbounds) < 2 {
		t.Fatal("expected mixed and tun inbounds")
	}
	tunInbound, ok := inbounds[1].(map[string]any)
	if !ok || tunInbound["type"] != "tun" || tunInbound["auto_route"] != true {
		t.Fatal("invalid tun inbound config")
	}
	if tunInbound["interface_name"] == "" {
		t.Fatal("empty interface name")
	}
}

func TestWindowsTunConfigKeepsStrictRouteAndExcludesServer(t *testing.T) {
	cfg, err := buildConfigForOS(map[string]any{"type": "vless", "tag": "proxy", "server": "192.0.2.1", "server_port": 443, "uuid": "00000000-0000-4000-8000-000000000001"}, true, "", ConnectionSettings{}, "windows")
	if err != nil {
		t.Fatal(err)
	}
	inbounds, ok := cfg["inbounds"].([]any)
	if !ok || len(inbounds) < 2 {
		t.Fatal("expected mixed and tun inbounds")
	}
	tunInbound, ok := inbounds[1].(map[string]any)
	if !ok {
		t.Fatal("invalid tun inbound")
	}
	if tunInbound["interface_name"] != "Velum" || tunInbound["strict_route"] != true {
		t.Fatalf("unexpected Windows tun inbound: %#v", tunInbound)
	}
	for _, key := range []string{"iproute2_table_index", "iproute2_rule_index"} {
		if _, exists := tunInbound[key]; exists {
			t.Fatalf("Linux-only routing option %s leaked into Windows config", key)
		}
	}
	if err = excludeTunServer(cfg, "192.0.2.1"); err != nil {
		t.Fatal(err)
	}
	excluded, ok := tunInbound["route_exclude_address"].([]string)
	if !ok || len(excluded) != 1 || excluded[0] != "192.0.2.1/32" {
		t.Fatalf("server address was not excluded from TUN: %#v", tunInbound["route_exclude_address"])
	}
	if err = excludeTunServer(cfg, "not-an-ip"); err != nil {
		t.Fatal(err)
	}
	excluded, _ = tunInbound["route_exclude_address"].([]string)
	if len(excluded) != 1 {
		t.Fatal("non-IP endpoint must not create a route exclusion")
	}
	if primaryServer(cfg) != "192.0.2.1" {
		t.Fatal("primary server was not read from the config")
	}
	checkCoreConfig(t, cfg)
}

func TestLinuxTunRoutingNamespace(t *testing.T) {
	cfg, err := buildConfigForOS(map[string]any{"type": "socks", "tag": "proxy", "server": "192.0.2.1", "server_port": 1080}, true, "", ConnectionSettings{}, "linux")
	if err != nil {
		t.Fatal(err)
	}
	inbound := cfg["inbounds"].([]any)[1].(map[string]any)
	if inbound["iproute2_table_index"] != 27841 || inbound["iproute2_rule_index"] != 27841 {
		t.Fatalf("Linux TUN must not use shared sing-tun defaults: %#v", inbound)
	}
	checkCoreConfig(t, cfg)
}

func TestCompanionServerExtraction(t *testing.T) {
	companion := map[string]any{"outbounds": []any{map[string]any{"protocol": "vless", "settings": map[string]any{"vnext": []any{map[string]any{"address": "198.51.100.7", "port": 443}}}}}}
	if got := companionServer(companion); got != "198.51.100.7" {
		t.Fatalf("unexpected companion address: %q", got)
	}
	if got := companionServer(nil); got != "" {
		t.Fatalf("nil companion must return an empty address, got %q", got)
	}
}
