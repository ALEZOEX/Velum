package main

import (
	"regexp"
	"strings"
	"sync"
	"time"
)

type LogEntry struct {
	Time    string `json:"time"`
	Level   string `json:"level"`
	Message string `json:"message"`
}
type logBuffer struct {
	mu      sync.Mutex
	lines   []LogEntry
	pending string
	secrets []string
}

var ansi = regexp.MustCompile(`\x1b\[[0-9;]*m`)
var linkSecret = regexp.MustCompile(`(?i)(vless|vmess|ss|trojan|hysteria2|hy2|socks5?)://[^\s]+`)

func (l *logBuffer) setSecrets(values []string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.secrets = values
	l.pending = ""
}
func collectSecrets(cfg map[string]any, uri, apiSecret string) []string {
	result := []string{uri, apiSecret}
	var visit func(any)
	visit = func(v any) {
		switch value := v.(type) {
		case map[string]any:
			for k, v := range value {
				if k == "password" || k == "uuid" || k == "public_key" || k == "private_key" || k == "username" || k == "id" || k == "pass" || k == "publicKey" || k == "privateKey" || k == "shortId" {
					if text, ok := v.(string); ok && len(text) >= 4 {
						result = append(result, text)
					}
				}
				visit(v)
			}
		case []any:
			for _, v := range value {
				visit(v)
			}
		}
	}
	visit(cfg)
	return result
}
func (l *logBuffer) clean(value string) string {
	value = ansi.ReplaceAllString(value, "")
	value = linkSecret.ReplaceAllString(value, "[скрытая ссылка]")
	for _, secret := range l.secrets {
		if len(secret) >= 4 {
			value = strings.ReplaceAll(value, secret, "[скрыто]")
		}
	}
	if len(value) > 2048 {
		value = value[:2048] + "…"
	}
	return strings.TrimSpace(value)
}
func (l *logBuffer) append(level, message string) {
	message = l.clean(message)
	if message == "" {
		return
	}
	l.lines = append(l.lines, LogEntry{Time: time.Now().UTC().Format(time.RFC3339), Level: level, Message: message})
	if len(l.lines) > 300 {
		l.lines = append([]LogEntry(nil), l.lines[len(l.lines)-300:]...)
	}
}
func (l *logBuffer) add(level, message string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.append(level, message)
}
func (l *logBuffer) Write(p []byte) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.pending += string(p)
	if len(l.pending) > 16384 {
		l.pending = l.pending[len(l.pending)-16384:]
	}
	parts := strings.Split(l.pending, "\n")
	l.pending = parts[len(parts)-1]
	for _, line := range parts[:len(parts)-1] {
		level := "info"
		upper := strings.ToUpper(line)
		if strings.Contains(upper, "ERROR") || strings.Contains(upper, "FATAL") {
			level = "error"
		}
		l.append(level, line)
	}
	return len(p), nil
}
func (l *logBuffer) entries() []LogEntry {
	l.mu.Lock()
	defer l.mu.Unlock()
	result := make([]LogEntry, len(l.lines))
	copy(result, l.lines)
	return result
}
func (l *logBuffer) clear() { l.mu.Lock(); defer l.mu.Unlock(); l.lines = nil; l.pending = "" }
