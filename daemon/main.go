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
	xrayCmd                                              *exec.Cmd
	xrayDone                                             chan struct{}
	xray                                                 string
	done                                                 chan struct{}
	state, lastError, core, interfaceName, dir, token    string
	tun                                                  bool
	tunActive                                            bool
	proxyPort                                            int
	connectedAt                                          time.Time
	verified                                             bool
	latencyMs                                            *int64
	activeProfile                                        string
	desired                                              *ConnectRequest
	reconnectAt                                          time.Time
	reconnectAttempts                                    int
	apiAddress, apiSecret                                string
	serviceMode, activeInterface                         string
	uploadTotal, downloadTotal, uploadRate, downloadRate *int64
	sampleAt                                             time.Time
	logs                                                 logBuffer
}

func (s *service) stopCore() {
	if s.cmd != nil {
		select {
		case <-s.done:
		default:
			interruptProcess(s.cmd)
			select {
			case <-s.done:
			case <-time.After(4 * time.Second):
				_ = s.cmd.Process.Kill()
				<-s.done
			}
		}
	}
	stopProcess(s.xrayCmd, s.xrayDone)
	s.xrayCmd = nil
	s.xrayDone = nil
	if s.dir != "" {
		_ = os.Remove(filepath.Join(s.dir, "xray.json"))
	}
	s.cmd = nil
	s.state = "disconnected"
	s.verified = false
	s.latencyMs = nil
	s.connectedAt = time.Time{}
	s.apiAddress = ""
	s.apiSecret = ""
	s.activeInterface = ""
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
	var cfg, companionConfig map[string]any
	var err error
	var bridgeAddress string
	activeInterface := s.interfaceName
	if req.Settings.Interface != "" {
		activeInterface = req.Settings.Interface
	}
	if isXHTTP(req.URI) {
		if s.xray == "" {
			return errors.New("Для XHTTP необходимо установить Xray и запустить службу с --xray /полный/путь/xray")
		}
		if req.Settings.Fragment {
			return errors.New("Для XHTTP отключите TLS-фрагментацию: она пока доступна только в sing-box")
		}
		iface := activeInterface
		if tun && iface == "" {
			u, _ := url.Parse(req.URI)
			targetHost := ""
			if u != nil {
				targetHost = u.Hostname()
			}
			detected, detErr := detectOutboundInterface(targetHost)
			if detErr == nil && detected != "" {
				iface = detected
			} else {
				return errors.New("Для XHTTP в TUN не удалось автоматически определить физический интерфейс; укажите его в настройках")
			}
		}
		bridgeAddress, err = freeAddress()
		if err != nil {
			return errors.New("Не удалось выделить локальный порт Xray")
		}
		password, e := randomBridgePassword()
		if e != nil {
			return e
		}
		companionConfig, err = xrayConfig(req.URI, bridgeAddress, password, iface)
		if err != nil {
			return err
		}
		activeInterface = iface
		bridge, e := bridgeOutbound(bridgeAddress, password)
		if e != nil {
			return e
		}
		cfg, err = buildConfigWithOutbound(bridge, tun, s.interfaceName, req.Settings)
	} else {
		cfg, err = buildConfig(req.URI, tun, s.interfaceName, req.Settings)
	}
	if err != nil {
		return err
	}
	if err = applyExclusions(cfg, req.Exclusions); err != nil {
		return err
	}
	if tun {
		remote := companionServer(companionConfig)
		if remote == "" {
			remote = primaryServer(cfg)
		}
		if err = excludeTunServer(cfg, remote); err != nil {
			return err
		}
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
	xrayCandidate := filepath.Join(s.dir, "candidate-xray.json")
	if companionConfig != nil {
		defer os.Remove(xrayCandidate)
		if err = writeCheckedXray(s.xray, xrayCandidate, companionConfig); err != nil {
			return err
		}
	}
	s.stopCore()
	if err = os.Rename(candidate, path); err != nil {
		return err
	}
	cmd := exec.Command(s.core, "run", "-c", path)
	secrets := collectSecrets(cfg, req.URI, secret)
	if companionConfig != nil {
		secrets = append(secrets, collectSecrets(companionConfig, req.URI, secret)...)
	}
	s.logs.setSecrets(secrets)
	success := false
	defer func() {
		if !success {
			s.stopCore()
		}
	}()
	if companionConfig != nil {
		xrayPath := filepath.Join(s.dir, "xray.json")
		if err = os.Rename(xrayCandidate, xrayPath); err != nil {
			return err
		}
		s.xrayCmd, s.xrayDone, err = startCompanion(s.xray, xrayPath, bridgeAddress, &s.logs)
		if err != nil {
			return err
		}
	}
	cmd.Stdout = &s.logs
	cmd.Stderr = &s.logs
	configureChild(cmd)
	if err = cmd.Start(); err != nil {
		return errors.New("Не удалось запустить sing-box")
	}
	if err = afterStart(cmd); err != nil {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
		s.logs.add("error", err.Error())
		return errors.New("Не удалось привязать sing-box к задаче службы")
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
		if s.xrayCmd != nil {
			select {
			case <-s.xrayDone:
				return errors.New("Xray завершился при запуске")
			default:
			}
		}
		s.state = "running"
		s.lastError = ""
		s.tunActive = tun
		s.activeInterface = activeInterface
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
		success = true
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
	message := ""
	if s.xrayCmd != nil {
		select {
		case <-s.xrayDone:
			message = "Ядро Xray неожиданно завершилось"
		default:
		}
	}
	if s.cmd != nil {
		select {
		case <-s.done:
			message = "Сетевое ядро неожиданно завершилось"
		default:
		}
	}
	if message != "" {
		s.stopCore()
		s.state = "error"
		s.lastError = message
		s.logs.add("error", message)
		s.reconnectAt = time.Now().Add(2 * time.Second)
	}
}
func (s *service) inspectInterface() {
	if s.state != "running" || s.activeInterface == "" {
		return
	}
	if _, err := net.InterfaceByName(s.activeInterface); err == nil {
		return
	}
	message := fmt.Sprintf("Исходящий интерфейс %s больше не доступен", s.activeInterface)
	s.stopCore()
	s.state = "error"
	s.lastError = message
	s.logs.add("error", message)
	s.reconnectAt = time.Now().Add(2 * time.Second)
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
			s.inspectInterface()
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
	engine := "sing-box"
	if s.xrayCmd != nil {
		engine = "sing-box+xray"
	}
	engineState := "stopped"
	switch s.state {
	case "running":
		engineState = "running"
	case "error":
		engineState = "error"
	}
	return map[string]any{"state": s.state, "error": s.lastError, "mode": mode, "proxy": fmt.Sprintf("127.0.0.1:%d", port), "connectedAt": at, "uptimeSeconds": uptime, "verified": s.verified, "latencyMs": s.latencyMs, "activeProfile": s.activeProfile, "uploadTotal": s.uploadTotal, "downloadTotal": s.downloadTotal, "uploadRate": s.uploadRate, "downloadRate": s.downloadRate, "tunAllowed": s.tun, "reconnectAttempts": s.reconnectAttempts, "xrayAvailable": s.xray != "", "engine": engine, "engineState": engineState, "serviceMode": s.serviceMode}
}
func probe(uri string) map[string]any {
	probeURI := uri
	if isXHTTP(uri) {
		if _, err := xrayConfig(uri, "127.0.0.1:12345", "validation-only", ""); err != nil {
			return map[string]any{"ok": false, "error": err.Error(), "kind": "tcp", "latencyMs": nil}
		}
		u, _ := url.Parse(uri)
		q := u.Query()
		q.Set("type", "tcp")
		u.RawQuery = q.Encode()
		probeURI = u.String()
	}
	out, err := outbound(probeURI)
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

type daemonConfig struct {
	core, xray, tokenFile, interfaceName string
	tunAllowed                           bool
	managedBy                            string
}

type daemonRuntime struct {
	svc      *service
	server   *http.Server
	listener net.Listener
	dir      string
}

func defaultTokenFile() string {
	if value := os.Getenv("VELUM_TOKEN_FILE"); value != "" {
		return value
	}
	if runtime.GOOS != "windows" {
		return ""
	}
	if data := os.Getenv("ProgramData"); data != "" {
		path := filepath.Join(data, "Velum", "token")
		if _, err := os.Stat(path); err == nil {
			return path
		}
	}
	if home := os.Getenv("USERPROFILE"); home != "" {
		return filepath.Join(home, ".config", "velum", "token")
	}
	return ""
}

func resolvePaths(cfg *daemonConfig) error {
	if cfg.core == "" {
		executable, err := os.Executable()
		if err != nil {
			return err
		}
		name := "sing-box"
		if runtime.GOOS == "windows" {
			name += ".exe"
		}
		cfg.core = filepath.Join(filepath.Dir(executable), name)
		if info, err := os.Stat(cfg.core); err != nil || !info.Mode().IsRegular() {
			if located, err := exec.LookPath(name); err == nil {
				cfg.core = located
			}
		}
	}
	if cfg.xray == "" {
		name := "xray"
		if runtime.GOOS == "windows" {
			name += ".exe"
		}
		candidate := filepath.Join(filepath.Dir(cfg.core), name)
		if info, err := os.Stat(candidate); err == nil && info.Mode().IsRegular() {
			cfg.xray = candidate
		}
	}
	if cfg.tokenFile == "" {
		cfg.tokenFile = defaultTokenFile()
	}
	return nil
}

func prepareDaemon(cfg daemonConfig) (*daemonRuntime, error) {
	if err := resolvePaths(&cfg); err != nil {
		return nil, err
	}
	if cfg.tokenFile == "" {
		return nil, errors.New("token file is required")
	}
	if err := validateXrayExecutable(cfg.xray); err != nil {
		return nil, err
	}
	if err := (ConnectionSettings{Interface: cfg.interfaceName}).validate(cfg.tunAllowed); err != nil {
		return nil, err
	}
	if !filepath.IsAbs(cfg.core) {
		return nil, errors.New("core path must be absolute")
	}
	info, err := os.Stat(cfg.core)
	if err != nil || !info.Mode().IsRegular() {
		return nil, errors.New("sing-box executable not found")
	}
	vctx, vcancel := context.WithTimeout(context.Background(), 5*time.Second)
	version, verr := exec.CommandContext(vctx, cfg.core, "version").Output()
	vcancel()
	if verr != nil || !strings.Contains(string(version), "sing-box version 1.12.12\n") {
		return nil, errors.New("requires sing-box 1.12.12; rebuild using make core")
	}
	ti, err := os.Stat(cfg.tokenFile)
	if err != nil || !ti.Mode().IsRegular() || ti.Size() > 256 || (runtime.GOOS != "windows" && ti.Mode().Perm()&0077 != 0) {
		return nil, errors.New("token file must be a private regular file (0600)")
	}
	b, err := os.ReadFile(cfg.tokenFile)
	if err != nil {
		return nil, err
	}
	token := strings.TrimSpace(string(b))
	if len(token) < 32 {
		return nil, errors.New("token must contain at least 32 characters")
	}
	dir, err := os.MkdirTemp("", "velum-core-")
	if err != nil {
		return nil, err
	}
	managedBy := cfg.managedBy
	if managedBy == "" {
		managedBy = "console"
	}
	s := &service{xray: cfg.xray, core: cfg.core, interfaceName: cfg.interfaceName, tun: cfg.tunAllowed, dir: dir, token: token, state: "disconnected", serviceMode: managedBy}
	listener, err := net.Listen("tcp4", "127.0.0.1:27841")
	if err != nil {
		_ = os.RemoveAll(dir)
		return nil, err
	}
	server := &http.Server{Handler: http.HandlerFunc(s.handler), ReadHeaderTimeout: 3 * time.Second, ReadTimeout: 15 * time.Second, WriteTimeout: 30 * time.Second, IdleTimeout: 15 * time.Second, MaxHeaderBytes: 4096}
	return &daemonRuntime{svc: s, server: server, listener: listener, dir: dir}, nil
}

func (d *daemonRuntime) serve(ctx context.Context) error {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	go d.svc.monitor(ctx)
	go func() { <-ctx.Done(); _ = d.server.Close() }()
	err := d.server.Serve(d.listener)
	cancel()
	d.svc.mu.Lock()
	tunWasActive := d.svc.tunActive
	d.svc.stop()
	d.svc.mu.Unlock()
	cleanupNetworkState(tunWasActive)
	_ = os.RemoveAll(d.dir)
	if err != nil && err != http.ErrServerClosed {
		return err
	}
	return nil
}

func main() {
	core := flag.String("core", "", "Absolute path to trusted sing-box 1.12.12 (default: beside the executable)")
	tokenFile := flag.String("token-file", "", "Existing private token file")
	tun := flag.Bool("tun", false, "Allow TUN (requires network privileges)")
	interfaceName := flag.String("interface", "", "Bind outbound sockets to this existing interface")
	xray := flag.String("xray", "", "Absolute path to trusted optional Xray executable for XHTTP")
	serviceAction := flag.String("service", "", "Windows service action: install, uninstall or run")
	serviceAccount := flag.String("service-account", "", "Optional Windows service account (default: LocalSystem)")
	flag.Parse()
	cfg := daemonConfig{core: *core, xray: *xray, tokenFile: *tokenFile, interfaceName: *interfaceName, tunAllowed: *tun}
	if *serviceAction != "" {
		if err := runServiceAction(*serviceAction, cfg, *serviceAccount); err != nil {
			log.Fatal(err)
		}
		return
	}
	runtime, err := prepareDaemon(cfg)
	if err != nil {
		log.Fatal(err)
	}
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	fmt.Println("Velum API: 127.0.0.1:27841")
	if err := runtime.serve(ctx); err != nil {
		log.Print(err)
	}
}
