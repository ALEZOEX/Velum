package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

func detectOutboundInterface(targetHost string) (string, error) {
	if targetHost == "" {
		targetHost = "1.1.1.1"
	}
	if h, _, err := net.SplitHostPort(targetHost); err == nil {
		targetHost = h
	}
	ips, err := net.LookupIP(targetHost)
	if err != nil || len(ips) == 0 {
		return "", errors.New("не удалось разрешить адрес для выбора интерфейса")
	}
	conn, err := net.DialUDP("udp", nil, &net.UDPAddr{IP: ips[0], Port: 53})
	if err != nil {
		return "", err
	}
	defer conn.Close()
	localIP := conn.LocalAddr().(*net.UDPAddr).IP

	ifaces, err := net.Interfaces()
	if err != nil {
		return "", err
	}
	for _, iface := range ifaces {
		nameLower := strings.ToLower(iface.Name)
		if iface.Flags&net.FlagLoopback != 0 || iface.Flags&net.FlagUp == 0 || strings.HasPrefix(nameLower, "velum") {
			continue
		}
		addrs, err := iface.Addrs()
		if err != nil {
			continue
		}
		for _, addr := range addrs {
			var ip net.IP
			switch v := addr.(type) {
			case *net.IPNet:
				ip = v.IP
			case *net.IPAddr:
				ip = v.IP
			}
			if ip != nil && ip.Equal(localIP) {
				return iface.Name, nil
			}
		}
	}
	return "", errors.New("не удалось сопоставить локальный адрес с физическим интерфейсом")
}

func isXHTTP(raw string) bool {
	u, e := url.Parse(raw)
	if e != nil {
		return false
	}
	kind := u.Query().Get("type")
	return kind == "xhttp" || kind == "splithttp"
}

func xrayConfig(raw, address, password, interfaceName string) (map[string]any, error) {
	u, e := url.Parse(raw)
	if e != nil || u.Scheme != "vless" {
		return nil, errors.New("XHTTP поддерживается для VLESS-ссылок")
	}
	q, e := url.ParseQuery(u.RawQuery)
	if e != nil {
		return nil, errors.New("Некорректные параметры XHTTP")
	}
	// Reuse strict credential/TLS/parameter validation without substituting the original URI.
	validation := *u
	vq := validation.Query()
	vq.Set("type", "tcp")
	validation.RawQuery = vq.Encode()
	out, e := outbound(validation.String())
	if e != nil {
		return nil, e
	}
	if e = resolveEndpoint(out); e != nil {
		return nil, e
	}
	mode := q.Get("mode")
	if mode == "" {
		mode = "auto"
	}
	if mode != "auto" && mode != "packet-up" && mode != "stream-up" && mode != "stream-one" {
		return nil, errors.New("Неизвестный режим XHTTP")
	}
	if q.Get("flow") != "" {
		return nil, errors.New("XHTTP не использует XTLS Vision flow; проверьте ссылку провайдера")
	}
	_, port, e := net.SplitHostPort(address)
	if e != nil {
		return nil, e
	}
	socksPort, e := strconv.Atoi(port)
	if e != nil {
		return nil, e
	}
	path := q.Get("path")
	if path == "" {
		path = "/"
	}
	security := q.Get("security")
	if security == "" {
		security = "none"
	}
	stream := map[string]any{"network": "xhttp", "security": security, "xhttpSettings": map[string]any{"path": path, "host": q.Get("host"), "mode": mode}}
	if interfaceName != "" {
		stream["sockopt"] = map[string]any{"interface": interfaceName}
	}
	sni := q.Get("sni")
	if sni == "" {
		sni = q.Get("peer")
	}
	if sni == "" {
		sni = u.Hostname()
	}
	if security == "reality" {
		fp := q.Get("fp")
		if fp == "" {
			fp = "chrome"
		}
		stream["realitySettings"] = map[string]any{"serverName": sni, "fingerprint": fp, "publicKey": q.Get("pbk"), "shortId": q.Get("sid")}
	} else if security == "tls" {
		tls := map[string]any{"serverName": sni}
		if q.Get("fp") != "" {
			tls["fingerprint"] = q.Get("fp")
		}
		if q.Get("alpn") != "" {
			tls["alpn"] = strings.Split(q.Get("alpn"), ",")
		}
		stream["tlsSettings"] = tls
	}
	return map[string]any{
		"log":       map[string]any{"loglevel": "warning"},
		"inbounds":  []any{map[string]any{"tag": "velum-bridge", "listen": "127.0.0.1", "port": socksPort, "protocol": "socks", "settings": map[string]any{"auth": "password", "accounts": []any{map[string]any{"user": "velum", "pass": password}}, "udp": true}}},
		"outbounds": []any{map[string]any{"tag": "proxy", "protocol": "vless", "settings": map[string]any{"vnext": []any{map[string]any{"address": out["server"], "port": out["server_port"], "users": []any{map[string]any{"id": out["uuid"], "encryption": "none"}}}}}, "streamSettings": stream}},
	}, nil
}

func randomBridgePassword() (string, error) {
	var b [32]byte
	_, e := rand.Read(b[:])
	return hex.EncodeToString(b[:]), e
}

func bridgeOutbound(address, password string) (map[string]any, error) {
	host, port, e := net.SplitHostPort(address)
	if e != nil {
		return nil, e
	}
	p, e := strconv.Atoi(port)
	if e != nil {
		return nil, e
	}
	out := map[string]any{"type": "socks", "tag": "proxy", "server": host, "server_port": p, "version": "5", "username": "velum", "password": password}
	// The global physical-interface binding must not divert this loopback hop.
	interfaces, e := net.Interfaces()
	if e != nil {
		return nil, e
	}
	for _, iface := range interfaces {
		if iface.Flags&net.FlagLoopback != 0 {
			out["bind_interface"] = iface.Name
			return out, nil
		}
	}
	return nil, errors.New("Не найден loopback-интерфейс для Xray")
}

func validateXrayExecutable(path string) error {
	if path == "" {
		return nil
	}
	if !filepath.IsAbs(path) {
		return errors.New("Xray requires an absolute trusted executable path")
	}
	info, e := os.Stat(path)
	if e != nil || !info.Mode().IsRegular() {
		return errors.New("Xray executable not found")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	output, e := exec.CommandContext(ctx, path, "version").Output()
	if e != nil || !strings.HasPrefix(string(output), "Xray 26.10.31 ") {
		return errors.New("requires Xray 26.10.31; build using make xray")
	}
	return nil
}

func writeCheckedXray(executable, path string, cfg map[string]any) error {
	data, e := json.Marshal(cfg)
	if e != nil {
		return e
	}
	if e = os.WriteFile(path, data, 0600); e != nil {
		return e
	}
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	if exec.CommandContext(ctx, executable, "run", "-test", "-config", path).Run() != nil {
		return errors.New("Xray отклонил конфигурацию XHTTP; проверьте параметры ссылки")
	}
	return nil
}

func stopProcess(cmd *exec.Cmd, done chan struct{}) {
	if cmd == nil {
		return
	}
	select {
	case <-done:
		return
	default:
	}
	_ = cmd.Process.Signal(os.Interrupt)
	select {
	case <-done:
	case <-time.After(4 * time.Second):
		_ = cmd.Process.Kill()
		<-done
	}
}
func startCompanion(executable, path, address string, logs *logBuffer) (*exec.Cmd, chan struct{}, error) {
	cmd := exec.Command(executable, "run", "-config", path)
	cmd.Stdout = logs
	cmd.Stderr = logs
	if e := cmd.Start(); e != nil {
		return nil, nil, errors.New("Не удалось запустить Xray")
	}
	done := make(chan struct{})
	go func() { _ = cmd.Wait(); close(done) }()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		select {
		case <-done:
			return nil, nil, errors.New("Xray завершился при запуске; проверьте журнал")
		default:
		}
		connection, e := net.DialTimeout("tcp", address, 100*time.Millisecond)
		if e == nil {
			connection.Close()
			return cmd, done, nil
		}
		time.Sleep(25 * time.Millisecond)
	}
	stopProcess(cmd, done)
	return nil, nil, errors.New("Локальный прокси Xray не запустился")
}
