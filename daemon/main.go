package main

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

type ConnectRequest struct {
	URI        string             `json:"uri"`
	Exclusions []string           `json:"exclusions,omitempty"`
	Settings   ConnectionSettings `json:"settings,omitempty"`
}
type service struct {
	mu                                                   sync.Mutex
	cmd                                                  *exec.Cmd
	done                                                 chan struct{}
	state, lastError, core, interfaceName, dir, token    string
	tun                                                  bool
	proxyPort                                            int
	connectedAt                                          time.Time
	verified                                             bool
	latencyMs                                            *int64
	activeProfile                                        string
	desired                                              *ConnectRequest
	reconnectAt                                          time.Time
	reconnectAttempts                                    int
	apiAddress, apiSecret                                string
	uploadTotal, downloadTotal, uploadRate, downloadRate *int64
	sampleAt                                             time.Time
	logs                                                 logBuffer
}

func (s *service) stopCore() {
	if s.cmd != nil {
		select {
		case <-s.done:
		default:
			_ = s.cmd.Process.Signal(os.Interrupt)
			select {
			case <-s.done:
			case <-time.After(4 * time.Second):
				_ = s.cmd.Process.Kill()
				<-s.done
			}
		}
	}
	s.cmd = nil
	s.state = "disconnected"
	s.verified = false
	s.latencyMs = nil
	s.connectedAt = time.Time{}
	s.apiAddress = ""
	s.apiSecret = ""
}
func (s *service) stop() {
	s.desired = nil
	s.reconnectAttempts = 0
	s.stopCore()
	s.lastError = ""
	s.logs.add("info", "Соединение остановлено")
}
func (s *service) connect(uri string, exclusions ...string) error {
	return s.connectRequest(ConnectRequest{URI: uri, Exclusions: exclusions})
}
func (s *service) connectRequest(req ConnectRequest) error {
	if err := req.Settings.validate(s.tun); err != nil {
		return err
	}
	tun := s.tun
	if req.Settings.Mode != "" {
		tun = req.Settings.Mode == "tun"
	}
	cfg, err := buildConfig(req.URI, tun, s.interfaceName, req.Settings)
	if err != nil {
		return err
	}
	if err = applyExclusions(cfg, req.Exclusions); err != nil {
		return err
	}
	address, err := freeAddress()
	if err != nil {
		return errors.New("Не удалось выделить порт статистики")
	}
	random := make([]byte, 32)
	if _, err = rand.Read(random); err != nil {
		return err
	}
	secret := hex.EncodeToString(random)
	cfg["experimental"] = map[string]any{"clash_api": map[string]any{"external_controller": address, "secret": secret, "access_control_allow_origin": []string{"http://localhost.invalid"}}}
	data, err := json.Marshal(cfg)
	if err != nil {
		return err
	}
	path := filepath.Join(s.dir, "config.json")
	// A candidate is checked before replacing an existing connection.
	candidate := filepath.Join(s.dir, "candidate.json")
	if err = os.WriteFile(candidate, data, 0600); err != nil {
		return err
	}
	defer os.Remove(candidate)
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	if err = exec.CommandContext(ctx, s.core, "check", "-c", candidate).Run(); err != nil {
		return errors.New("sing-box отклонил конфигурацию; проверьте протокол, параметры и сборку ядра")
	}
	s.stopCore()
	if err = os.Rename(candidate, path); err != nil {
		return err
	}
	cmd := exec.Command(s.core, "run", "-c", path)
	s.logs.setSecrets(collectSecrets(cfg, req.URI, secret))
	cmd.Stdout = &s.logs
	cmd.Stderr = &s.logs
	if err = cmd.Start(); err != nil {
		return errors.New("Не удалось запустить sing-box")
	}
	s.cmd = cmd
	s.done = make(chan struct{})
	done := s.done
	go func() { _ = cmd.Wait(); close(done) }()
	select {
	case <-done:
		s.cmd = nil
		s.state = "error"
		return errors.New("Ядро завершилось при запуске; проверьте журнал, права TUN и занятость портов")
	case <-time.After(500 * time.Millisecond):
		s.state = "running"
		s.lastError = ""
		s.connectedAt = time.Now().UTC()
		s.apiAddress = address
		s.apiSecret = secret
		s.proxyPort = req.Settings.ProxyPort
		if s.proxyPort == 0 {
			s.proxyPort = 2080
		}
		digest := sha256.Sum256([]byte(req.URI))
		s.activeProfile = hex.EncodeToString(digest[:8])
		s.desired = &req
		s.reconnectAttempts = 0
		s.sampleAt = time.Time{}
		s.uploadTotal = nil
		s.downloadTotal = nil
		s.uploadRate = nil
		s.downloadRate = nil
		s.logs.add("info", "Сетевое ядро запущено")
		return nil
	}
}
func freeAddress() (string, error) {
	l, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return "", err
	}
	address := l.Addr().String()
	err = l.Close()
	return address, err
}
func decodeBody(w http.ResponseWriter, r *http.Request, target any) error {
	d := json.NewDecoder(http.MaxBytesReader(w, r.Body, 131072))
	d.DisallowUnknownFields()
	if err := d.Decode(target); err != nil {
		return errors.New("Некорректное тело запроса")
	}
	var extra any
	if d.Decode(&extra) != io.EOF {
		return errors.New("Лишние данные запроса")
	}
	return nil
}
func (s *service) coreRequest(path string, target any) error {
	if s.apiAddress == "" {
		return errors.New("API ядра недоступен")
	}
	timeout := 10 * time.Second
	if path == "/connections" {
		timeout = 1500 * time.Millisecond
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, "GET", "http://"+s.apiAddress+path, nil)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+s.apiSecret)
	client := http.Client{Transport: &http.Transport{Proxy: nil, ResponseHeaderTimeout: 9 * time.Second}, Timeout: 10 * time.Second}
	defer client.CloseIdleConnections()
	response, err := client.Do(req)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode != 200 {
		return errors.New("Ядро не подтвердило доступность сервера")
	}
	return json.NewDecoder(io.LimitReader(response.Body, 4<<20)).Decode(target)
}
func (s *service) refreshStats() {
	if s.state != "running" || s.apiAddress == "" {
		return
	}
	var values struct {
		Upload   int64 `json:"uploadTotal"`
		Download int64 `json:"downloadTotal"`
	}
	if s.coreRequest("/connections", &values) != nil {
		return
	}
	now := time.Now()
	up, down := int64(0), int64(0)
	if !s.sampleAt.IsZero() && s.uploadTotal != nil && s.downloadTotal != nil {
		seconds := now.Sub(s.sampleAt).Seconds()
		if seconds > 0 {
			up = int64(float64(max(int64(0), values.Upload-*s.uploadTotal)) / seconds)
			down = int64(float64(max(int64(0), values.Download-*s.downloadTotal)) / seconds)
		}
	}
	s.uploadTotal = &values.Upload
	s.downloadTotal = &values.Download
	s.uploadRate = &up
	s.downloadRate = &down
	s.sampleAt = now
}
func (s *service) check() error {
	if s.state != "running" {
		return errors.New("Сначала подключите сервер")
	}
	s.verified = false
	s.latencyMs = nil
	var result struct {
		Delay int64 `json:"delay"`
	}
	if err := s.coreRequest("/proxies/proxy/delay?timeout=8000&url="+url.QueryEscape("https://example.com"), &result); err != nil {
		return errors.New("Проверка HTTPS через выбранный сервер не прошла")
	}
	s.verified = true
	s.latencyMs = &result.Delay
	s.lastError = ""
	s.logs.add("info", "HTTPS через выбранный сервер проверен")
	return nil
}
func (s *service) inspectProcess() {
	if s.cmd != nil {
		select {
		case <-s.done:
			s.cmd = nil
			s.state = "error"
			s.verified = false
			s.lastError = "Сетевое ядро неожиданно завершилось"
			s.logs.add("error", s.lastError)
			s.reconnectAt = time.Now().Add(2 * time.Second)
		default:
		}
	}
}
func (s *service) monitor(ctx context.Context) {
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			s.mu.Lock()
			s.inspectProcess()
			if s.cmd == nil && s.desired != nil && s.desired.Settings.Reconnect && !time.Now().Before(s.reconnectAt) && s.reconnectAttempts < 5 {
				req := *s.desired
				attempt := s.reconnectAttempts + 1
				s.logs.add("info", "Повторный запуск сетевого ядра")
				if err := s.connectRequest(req); err != nil {
					s.lastError = err.Error()
					s.state = "error"
					s.reconnectAttempts = attempt
					s.reconnectAt = time.Now().Add(time.Duration(1<<attempt) * time.Second)
				}
			}
			s.refreshStats()
			s.mu.Unlock()
		}
	}
}
func (s *service) status() map[string]any {
	s.inspectProcess()
	mode := map[bool]string{true: "tun", false: "proxy"}[s.tun]
	if s.desired != nil && s.desired.Settings.Mode != "" {
		mode = s.desired.Settings.Mode
	}
	var at any
	uptime := int64(0)
	if !s.connectedAt.IsZero() {
		at = s.connectedAt.Format(time.RFC3339)
		uptime = int64(time.Since(s.connectedAt).Seconds())
	}
	port := s.proxyPort
	if port == 0 {
		port = 2080
	}
	return map[string]any{"state": s.state, "error": s.lastError, "mode": mode, "proxy": fmt.Sprintf("127.0.0.1:%d", port), "connectedAt": at, "uptimeSeconds": uptime, "verified": s.verified, "latencyMs": s.latencyMs, "activeProfile": s.activeProfile, "uploadTotal": s.uploadTotal, "downloadTotal": s.downloadTotal, "uploadRate": s.uploadRate, "downloadRate": s.downloadRate, "tunAllowed": s.tun, "reconnectAttempts": s.reconnectAttempts}
}
func probe(uri string) map[string]any {
	out, err := outbound(uri)
	if err != nil {
		return map[string]any{"ok": false, "error": err.Error(), "kind": "tcp", "latencyMs": nil}
	}
	if out["type"] == "hysteria2" {
		return map[string]any{"ok": false, "error": "TCP-проверка неприменима к UDP-протоколу Hysteria 2; используйте проверку соединения", "kind": "tcp", "latencyMs": nil}
	}
	start := time.Now()
	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
	defer cancel()
	dialer := net.Dialer{}
	conn, err := dialer.DialContext(ctx, "tcp", net.JoinHostPort(out["server"].(string), strconv.Itoa(out["server_port"].(int))))
	if err != nil {
		return map[string]any{"ok": false, "error": "TCP-порт сервера недоступен", "kind": "tcp", "latencyMs": nil}
	}
	_ = conn.Close()
	return map[string]any{"ok": true, "error": "", "kind": "tcp", "latencyMs": time.Since(start).Milliseconds()}
}
func (s *service) handler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	if subtle.ConstantTimeCompare([]byte(r.Header.Get("Authorization")), []byte("Bearer "+s.token)) != 1 {
		w.WriteHeader(401)
		_ = json.NewEncoder(w).Encode(map[string]string{"error": "Неверный токен службы"})
		return
	}
	if r.URL.Path == "/v1/logs" && r.Method == "GET" {
		_ = json.NewEncoder(w).Encode(map[string]any{"entries": s.logs.entries()})
		return
	}
	if r.URL.Path == "/v1/probe" && r.Method == "POST" {
		var req struct {
			URI string `json:"uri"`
		}
		if err := decodeBody(w, r, &req); err != nil {
			w.WriteHeader(400)
			_ = json.NewEncoder(w).Encode(map[string]string{"error": err.Error()})
			return
		}
		_ = json.NewEncoder(w).Encode(probe(req.URI))
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.inspectProcess()
	var err error
	switch {
	case r.Method == "GET" && r.URL.Path == "/v1/status":
	case r.Method == "POST" && r.URL.Path == "/v1/connect":
		var req ConnectRequest
		err = decodeBody(w, r, &req)
		if err == nil {
			err = s.connectRequest(req)
		}
	case r.Method == "POST" && r.URL.Path == "/v1/disconnect":
		s.stop()
	case r.Method == "POST" && r.URL.Path == "/v1/reconnect":
		if s.desired == nil {
			err = errors.New("Нет последнего соединения")
		} else {
			err = s.connectRequest(*s.desired)
		}
	case r.Method == "POST" && r.URL.Path == "/v1/check":
		err = s.check()
	case r.Method == "POST" && r.URL.Path == "/v1/logs/clear":
		s.logs.clear()
	default:
		w.WriteHeader(404)
		_ = json.NewEncoder(w).Encode(map[string]string{"error": "Неизвестный метод API"})
		return
	}
	if err != nil {
		s.lastError = err.Error()
		s.logs.add("error", err.Error())
		w.WriteHeader(400)
	}
	_ = json.NewEncoder(w).Encode(s.status())
}
func main() {
	core := flag.String("core", "/usr/bin/sing-box", "Absolute path to trusted sing-box 1.12.12")
	tokenFile := flag.String("token-file", "", "Existing private token file")
	tun := flag.Bool("tun", false, "Allow TUN (requires network privileges)")
	interfaceName := flag.String("interface", "", "Bind outbound sockets to this existing interface")
	flag.Parse()
	if err := (ConnectionSettings{Interface: *interfaceName}).validate(*tun); err != nil {
		log.Fatal(err)
	}
	if !filepath.IsAbs(*core) {
		log.Fatal("core path must be absolute")
	}
	info, err := os.Stat(*core)
	if err != nil || !info.Mode().IsRegular() {
		log.Fatal("sing-box executable not found")
	}
	vctx, vcancel := context.WithTimeout(context.Background(), 5*time.Second)
	version, verr := exec.CommandContext(vctx, *core, "version").Output()
	vcancel()
	if verr != nil || !strings.Contains(string(version), "sing-box version 1.12.12\n") {
		log.Fatal("requires sing-box 1.12.12; rebuild using make core")
	}
	ti, err := os.Stat(*tokenFile)
	if err != nil || !ti.Mode().IsRegular() || ti.Size() > 256 || (runtime.GOOS != "windows" && ti.Mode().Perm()&0077 != 0) {
		log.Fatal("token file must be a private regular file (0600)")
	}
	b, err := os.ReadFile(*tokenFile)
	if err != nil {
		log.Fatal(err)
	}
	token := strings.TrimSpace(string(b))
	if len(token) < 32 {
		log.Fatal("token must contain at least 32 characters")
	}
	dir, err := os.MkdirTemp("", "velum-core-")
	if err != nil {
		log.Fatal(err)
	}
	defer os.RemoveAll(dir)
	s := &service{core: *core, interfaceName: *interfaceName, tun: *tun, dir: dir, token: token, state: "disconnected"}
	listener, err := net.Listen("tcp4", "127.0.0.1:27841")
	if err != nil {
		log.Fatal(err)
	}
	server := &http.Server{Handler: http.HandlerFunc(s.handler), ReadHeaderTimeout: 3 * time.Second, ReadTimeout: 15 * time.Second, WriteTimeout: 30 * time.Second, IdleTimeout: 15 * time.Second, MaxHeaderBytes: 4096}
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	go s.monitor(ctx)
	go func() { <-ctx.Done(); _ = server.Close() }()
	fmt.Println("Velum API: 127.0.0.1:27841")
	err = server.Serve(listener)
	cancel()
	s.mu.Lock()
	s.stop()
	s.mu.Unlock()
	if err != nil && err != http.ErrServerClosed {
		log.Print(err)
	}
}
