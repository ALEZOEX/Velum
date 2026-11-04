package main

import (
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

const xhttpTestURI = "vless://00000000-0000-4000-8000-000000000001@192.0.2.1:8545?security=reality&type=xhttp&sni=example.com&pbk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&sid=abcd&path=%2Fxhttp%2Fpath&host=cdn.example.com&mode=stream-up"

func TestXrayProfilePreservesXHTTP(t *testing.T) {
	cfg, e := xrayConfig(xhttpTestURI, "127.0.0.1:12345", "test-password", "")
	if e != nil {
		t.Fatal(e)
	}
	out := cfg["outbounds"].([]any)[0].(map[string]any)
	stream := out["streamSettings"].(map[string]any)
	xhttp := stream["xhttpSettings"].(map[string]any)
	if stream["network"] != "xhttp" || xhttp["path"] != "/xhttp/path" || xhttp["host"] != "cdn.example.com" || xhttp["mode"] != "stream-up" {
		t.Fatal("transport parameters changed")
	}
	peer := out["settings"].(map[string]any)["vnext"].([]any)[0].(map[string]any)
	if peer["port"] != 8545 {
		t.Fatal("server port changed")
	}
	reality := stream["realitySettings"].(map[string]any)
	if reality["serverName"] != "example.com" || reality["shortId"] != "abcd" {
		t.Fatal("Reality parameters changed")
	}
	for _, raw := range []string{strings.Replace(xhttpTestURI, "mode=stream-up", "mode=unsupported", 1), xhttpTestURI + "&flow=xtls-rprx-vision", xhttpTestURI + "&insecure=1", strings.Replace(xhttpTestURI, "sid=abcd", "sid=xyz", 1)} {
		if _, e = xrayConfig(raw, "127.0.0.1:12345", "test-password", ""); e == nil {
			t.Fatal("invalid XHTTP accepted")
		}
	}
	xray, _ := filepath.Abs("../bin/xray")
	if _, e = os.Stat(xray); e != nil {
		t.Skip("build Xray for real configuration validation")
	}
	if e = writeCheckedXray(xray, filepath.Join(t.TempDir(), "xray.json"), cfg); e != nil {
		t.Fatal(e)
	}
}

func testCorePaths(t *testing.T) (string, string) {
	t.Helper()
	core, _ := filepath.Abs("../bin/sing-box")
	xray, _ := filepath.Abs("../bin/xray")
	for _, p := range []string{core, xray} {
		if _, e := os.Stat(p); e != nil {
			t.Skip("build both pinned cores for XHTTP integration")
		}
	}
	return core, xray
}
func TestXrayBridgeHTTPAndCrashCleanup(t *testing.T) {
	core, xray := testCorePaths(t)
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte("actual-xhttp-response"))
	}))
	defer origin.Close()
	address, e := freeAddress()
	if e != nil {
		t.Fatal(e)
	}
	_, port, _ := net.SplitHostPort(address)
	number, _ := strconv.Atoi(port)
	cfg := map[string]any{"log": map[string]any{"loglevel": "warning"}, "inbounds": []any{map[string]any{"listen": "127.0.0.1", "port": number, "protocol": "vless", "settings": map[string]any{"clients": []any{map[string]any{"id": "00000000-0000-4000-8000-000000000001"}}, "decryption": "none"}, "streamSettings": map[string]any{"network": "xhttp", "security": "none", "xhttpSettings": map[string]any{"path": "/test-xhttp", "mode": "auto"}}}}, "outbounds": []any{map[string]any{"protocol": "freedom", "settings": map[string]any{"finalRules": []any{map[string]any{"action": "allow", "network": "tcp", "ip": []string{"127.0.0.1/32"}, "port": strings.Split(origin.URL, ":")[2]}}}}}}
	configPath := filepath.Join(t.TempDir(), "server.json")
	if e = writeCheckedXray(xray, configPath, cfg); e != nil {
		t.Fatal(e)
	}
	var logs logBuffer
	server, serverDone, e := startCompanion(xray, configPath, address, &logs)
	if e != nil {
		t.Fatal(e)
	}
	defer stopProcess(server, serverDone)
	local, e := freeAddress()
	if e != nil {
		t.Fatal(e)
	}
	_, port, _ = net.SplitHostPort(local)
	proxyPort, _ := strconv.Atoi(port)
	s := &service{core: core, xray: xray, dir: t.TempDir(), state: "disconnected"}
	defer s.stop()
	raw := "vless://00000000-0000-4000-8000-000000000001@" + address + "?type=xhttp&security=none&path=%2Ftest-xhttp&mode=auto"
	if e = s.connectRequest(ConnectRequest{URI: raw, Settings: ConnectionSettings{ProxyPort: proxyPort}}); e != nil {
		t.Fatal(e)
	}
	proxy, _ := url.Parse("http://" + local)
	transport := &http.Transport{Proxy: http.ProxyURL(proxy)}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: 10 * time.Second}
	response, e := client.Get(origin.URL)
	if e != nil {
		t.Logf("server logs: %+v; service logs: %+v", logs.entries(), s.logs.entries())
		t.Fatal(e)
	}
	body, e := io.ReadAll(response.Body)
	response.Body.Close()
	if e != nil || string(body) != "actual-xhttp-response" {
		t.Fatal("XHTTP did not forward actual HTTP")
	}
	if s.desired.URI != raw {
		t.Fatal("original profile was substituted")
	}
	primaryDone, companionDone := s.done, s.xrayDone
	if e = s.xrayCmd.Process.Kill(); e != nil {
		t.Fatal(e)
	}
	select {
	case <-companionDone:
	case <-time.After(3 * time.Second):
		t.Fatal("Xray wait did not finish")
	}
	s.inspectProcess()
	if s.state != "error" || s.cmd != nil || s.xrayCmd != nil {
		t.Fatal("companion crash left running state")
	}
	select {
	case <-primaryDone:
	default:
		t.Fatal("sing-box survived companion crash")
	}
	if _, e = os.Stat(filepath.Join(s.dir, "xray.json")); !os.IsNotExist(e) {
		t.Fatal("secret companion config remains")
	}
	// A subsequent connection must start cleanly and stop both children.
	if e = s.connectRequest(ConnectRequest{URI: raw, Settings: ConnectionSettings{ProxyPort: proxyPort}}); e != nil {
		t.Fatal(e)
	}
	primaryDone, companionDone = s.done, s.xrayDone
	s.stop()
	for _, done := range []chan struct{}{primaryDone, companionDone} {
		select {
		case <-done:
		default:
			t.Fatal("child survived stop")
		}
	}
}

func TestBridgeAuthenticationAndLoopback(t *testing.T) {
	out, e := bridgeOutbound("127.0.0.1:12345", "test-password")
	if e != nil {
		t.Fatal(e)
	}
	if out["password"] != "test-password" || out["username"] != "velum" || out["bind_interface"] == nil {
		t.Fatal("bridge is not authenticated/local")
	}
	cfg, e := buildConfigWithOutbound(out, false, "", ConnectionSettings{})
	if e != nil {
		t.Fatal(e)
	}
	checkCoreConfig(t, cfg)
	encoded, _ := json.Marshal(cfg)
	if !strings.Contains(string(encoded), "test-password") {
		t.Fatal("bridge credentials not forwarded")
	}
}
