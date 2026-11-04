package main

import (
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net"
	"net/url"
	"strconv"
	"strings"
)

func decodeBase64(value string) ([]byte, error) {
	value = strings.TrimSpace(value)
	for _, encoding := range []*base64.Encoding{base64.RawURLEncoding, base64.URLEncoding, base64.RawStdEncoding, base64.StdEncoding} {
		if data, err := encoding.DecodeString(value); err == nil {
			return data, nil
		}
	}
	return nil, errors.New("Некорректный Base64")
}
func validUUID(value string) bool {
	b, err := hex.DecodeString(strings.ReplaceAll(value, "-", ""))
	return err == nil && len(b) == 16
}
func credential(u *url.URL) string {
	if u.User == nil {
		return ""
	}
	value := u.User.Username()
	if p, ok := u.User.Password(); ok {
		value += ":" + p
	}
	return value
}
func outbound(raw string) (map[string]any, error) {
	raw = strings.TrimSpace(raw)
	if len(raw) > 16384 {
		return nil, errors.New("Ссылка слишком длинная")
	}
	if strings.HasPrefix(raw, "vmess://") && !strings.Contains(strings.Split(strings.TrimPrefix(raw, "vmess://"), "#")[0], "@") {
		return vmessOutbound(raw)
	}
	if strings.HasPrefix(raw, "ss://") {
		body := strings.TrimPrefix(raw, "ss://")
		plain := strings.SplitN(body, "#", 2)
		if !strings.Contains(plain[0], "@") {
			data, err := decodeBase64(plain[0])
			if err != nil {
				return nil, err
			}
			raw = "ss://" + string(data)
			if len(plain) > 1 {
				raw += "#" + plain[1]
			}
		}
	}
	u, err := url.Parse(raw)
	if err != nil || u.Hostname() == "" {
		return nil, errors.New("Некорректная ссылка сервера")
	}
	port, err := strconv.Atoi(u.Port())
	if err != nil || port < 1 || port > 65535 {
		return nil, errors.New("Нужен порт 1–65535")
	}
	q, err := url.ParseQuery(u.RawQuery)
	if err != nil {
		return nil, errors.New("Некорректные параметры ссылки")
	}
	allowed := "|security|type|flow|sni|peer|fp|pbk|sid|encryption|alpn|host|path|serviceName|mode|headerType|"
	switch u.Scheme {
	case "hysteria2", "hy2":
		allowed = "|sni|peer|alpn|obfs|obfs-password|"
	case "ss":
		allowed = "|"
	case "socks", "socks5", "http", "https":
		allowed = "|sni|"
	}
	for key, values := range q {
		if !strings.Contains(allowed, "|"+key+"|") || len(values) != 1 {
			return nil, errors.New("Ссылка содержит неподдерживаемый или повторный параметр")
		}
	}
	if u.Path != "" && u.Path != "/" {
		return nil, errors.New("Путь должен быть задан параметром path")
	}
	out := map[string]any{"type": u.Scheme, "tag": "proxy", "server": u.Hostname(), "server_port": port}
	switch u.Scheme {
	case "vless", "vmess":
		if u.User == nil || !validUUID(u.User.Username()) {
			return nil, errors.New("Некорректный UUID")
		}
		out["uuid"] = u.User.Username()
		if u.Scheme == "vless" {
			flow := q.Get("flow")
			if flow != "" && flow != "xtls-rprx-vision" {
				return nil, errors.New("Неподдерживаемый flow")
			}
			if flow != "" {
				out["flow"] = flow
			}
			if v := q.Get("encryption"); v != "" && v != "none" {
				return nil, errors.New("Неподдерживаемое encryption")
			}
		} else {
			out["security"] = "auto"
		}
		if err = applyLinkTLS(out, q, false); err != nil {
			return nil, err
		}
		if err = applyTransport(out, q); err != nil {
			return nil, err
		}
	case "trojan":
		if credential(u) == "" {
			return nil, errors.New("Пустой пароль Trojan")
		}
		out["password"] = credential(u)
		if err = applyLinkTLS(out, q, true); err != nil {
			return nil, err
		}
		if err = applyTransport(out, q); err != nil {
			return nil, err
		}
	case "hysteria2", "hy2":
		out["type"] = "hysteria2"
		if credential(u) == "" {
			return nil, errors.New("Пустой пароль Hysteria 2")
		}
		out["password"] = credential(u)
		if err = applyLinkTLS(out, q, true); err != nil {
			return nil, err
		}
		if ob := q.Get("obfs"); ob != "" {
			if ob != "salamander" || q.Get("obfs-password") == "" {
				return nil, errors.New("Некорректная обфускация")
			}
			out["obfs"] = map[string]any{"type": ob, "password": q.Get("obfs-password")}
		}
	case "ss":
		out["type"] = "shadowsocks"
		value := credential(u)
		if !strings.Contains(value, ":") {
			decoded, err := decodeBase64(value)
			if err != nil {
				return nil, err
			}
			value = string(decoded)
		}
		parts := strings.SplitN(value, ":", 2)
		if len(parts) != 2 || parts[0] == "" || parts[1] == "" {
			return nil, errors.New("Shadowsocks требует метод и пароль")
		}
		out["method"] = parts[0]
		out["password"] = parts[1]
	case "socks", "socks5", "http", "https":
		if u.Scheme == "socks5" || u.Scheme == "socks" {
			out["type"] = "socks"
			out["version"] = "5"
		} else {
			out["type"] = "http"
		}
		if u.User != nil {
			out["username"] = u.User.Username()
			if password, ok := u.User.Password(); ok {
				out["password"] = password
			}
		}
		if u.Scheme == "https" {
			out["tls"] = map[string]any{"enabled": true, "server_name": u.Hostname()}
		}
	default:
		return nil, errors.New("Протокол не поддерживается: используйте VLESS, VMess, Trojan, Shadowsocks, Hysteria 2, SOCKS5 или HTTP")
	}
	return out, nil
}
func applyLinkTLS(out map[string]any, q url.Values, defaultTLS bool) error {
	security := q.Get("security")
	if security == "" {
		if defaultTLS {
			security = "tls"
		} else {
			security = "none"
		}
	}
	if security == "none" {
		if q.Get("flow") == "xtls-rprx-vision" {
			return errors.New("Vision требует TLS или Reality")
		}
		return nil
	}
	if security != "tls" && security != "reality" {
		return errors.New("Неподдерживаемый тип TLS")
	}
	tls := map[string]any{"enabled": true}
	sni := q.Get("sni")
	if sni == "" {
		sni = q.Get("peer")
	}
	if sni != "" {
		tls["server_name"] = sni
	}
	if q.Get("alpn") != "" {
		tls["alpn"] = strings.Split(q.Get("alpn"), ",")
	}
	if fp := q.Get("fp"); fp != "" {
		tls["utls"] = map[string]any{"enabled": true, "fingerprint": fp}
	}
	if security == "reality" {
		key, err := base64.RawURLEncoding.DecodeString(q.Get("pbk"))
		if err != nil || len(key) != 32 || sni == "" {
			return errors.New("Reality требует SNI и 32-байтовый public key")
		}
		sid, err := hex.DecodeString(q.Get("sid"))
		if err != nil || len(sid) > 8 {
			return errors.New("Некорректный Reality short ID")
		}
		fp := q.Get("fp")
		if fp == "" {
			fp = "chrome"
		}
		tls["utls"] = map[string]any{"enabled": true, "fingerprint": fp}
		tls["reality"] = map[string]any{"enabled": true, "public_key": q.Get("pbk"), "short_id": q.Get("sid")}
	}
	out["tls"] = tls
	return nil
}
func applyTransport(out map[string]any, q url.Values) error {
	kind := q.Get("type")
	if kind == "" || kind == "tcp" {
		if h := q.Get("headerType"); h != "" && h != "none" {
			return errors.New("TCP headerType не поддерживается")
		}
		return nil
	}
	t := map[string]any{"type": kind}
	switch kind {
	case "ws", "httpupgrade":
		t["path"] = q.Get("path")
		if host := q.Get("host"); host != "" {
			t["headers"] = map[string]string{"Host": host}
		}
	case "grpc":
		t["service_name"] = q.Get("serviceName")
	case "http", "h2":
		t["type"] = "http"
		t["path"] = q.Get("path")
		if host := q.Get("host"); host != "" {
			t["host"] = strings.Split(host, ",")
		}
	case "xhttp", "splithttp":
		return errors.New("Для XHTTP требуется ядро Xray: запустите службу с --xray /полный/путь/xray")
	default:
		return errors.New("Транспорт не поддерживается ядром: доступны TCP, WebSocket, gRPC, HTTPUpgrade и HTTP/2")
	}
	out["transport"] = t
	return nil
}
func vmessOutbound(raw string) (map[string]any, error) {
	body := strings.SplitN(strings.TrimPrefix(raw, "vmess://"), "#", 2)[0]
	data, err := decodeBase64(body)
	if err != nil {
		return nil, err
	}
	var v map[string]json.RawMessage
	if json.Unmarshal(data, &v) != nil {
		return nil, errors.New("Некорректный VMess JSON")
	}
	str := func(key string) string {
		var s string
		if json.Unmarshal(v[key], &s) == nil {
			return s
		}
		var n json.Number
		if json.Unmarshal(v[key], &n) == nil {
			return string(n)
		}
		return ""
	}
	port, err := strconv.Atoi(str("port"))
	if err != nil || port < 1 || port > 65535 || str("add") == "" || !validUUID(str("id")) {
		return nil, errors.New("Некорректный адрес, порт или UUID VMess")
	}
	out := map[string]any{"type": "vmess", "tag": "proxy", "server": str("add"), "server_port": port, "uuid": str("id"), "security": "auto"}
	if scy := str("scy"); scy != "" {
		out["security"] = scy
	}
	if aid := str("aid"); aid != "" {
		n, e := strconv.Atoi(aid)
		if e != nil || n < 0 || n > 65535 {
			return nil, errors.New("Некорректный VMess alterId")
		}
		out["alter_id"] = n
	}
	q := url.Values{"type": {str("net")}, "host": {str("host")}, "path": {str("path")}, "sni": {str("sni")}, "fp": {str("fp")}, "alpn": {str("alpn")}}
	if q.Get("type") == "grpc" {
		q.Set("serviceName", str("path"))
	}
	if str("tls") == "tls" {
		q.Set("security", "tls")
	}
	if err = applyLinkTLS(out, q, false); err != nil {
		return nil, err
	}
	if err = applyTransport(out, q); err != nil {
		return nil, err
	}
	return out, nil
}
func resolveEndpoint(out map[string]any) error {
	host := out["server"].(string)
	if net.ParseIP(host) != nil {
		return nil
	}
	ips, err := net.LookupIP(host)
	if err != nil || len(ips) == 0 {
		return errors.New("Не удалось разрешить адрес сервера")
	}
	out["server"] = ips[0].String()
	if tls, ok := out["tls"].(map[string]any); ok {
		if _, exists := tls["server_name"]; !exists {
			tls["server_name"] = host
		}
	}
	return nil
}
func config(raw string, tun bool, interfaceName string) (map[string]any, error) {
	return buildConfig(raw, tun, interfaceName, ConnectionSettings{})
}
func applyExclusions(cfg map[string]any, values []string) error {
	if len(values) > 100 {
		return errors.New("Не более 100 исключений")
	}
	route := cfg["route"].(map[string]any)
	rules := route["rules"].([]any)
	for _, v := range values {
		if strings.TrimSpace(v) == "" {
			continue
		}
		kind := "domain"
		if _, _, err := net.ParseCIDR(v); err == nil {
			kind = "cidr"
		}
		r, err := compileRule(RouteRule{Action: "direct", Type: kind, Value: v})
		if err != nil {
			return err
		}
		rules = append(rules, r)
	}
	route["rules"] = rules
	outs := cfg["outbounds"].([]any)
	for _, v := range outs {
		if v.(map[string]any)["tag"] == "direct" {
			return nil
		}
	}
	cfg["outbounds"] = append(outs, map[string]any{"type": "direct", "tag": "direct"})
	return nil
}
