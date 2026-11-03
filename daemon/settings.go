package main

import (
	"errors"
	"net"
	"net/url"
	"strconv"
	"strings"
)

type RouteRule struct {
	Action string `json:"action"`
	Type   string `json:"type"`
	Value  string `json:"value"`
}
type ConnectionSettings struct {
	Mode      string      `json:"mode,omitempty"`
	MTU       int         `json:"mtu,omitempty"`
	IPv6      *bool       `json:"ipv6,omitempty"`
	DNS       string      `json:"dns,omitempty"`
	DirectDNS string      `json:"directDns,omitempty"`
	RouteMode string      `json:"routeMode,omitempty"`
	Rules     []RouteRule `json:"rules,omitempty"`
	Fragment  bool        `json:"fragment,omitempty"`
	Reconnect bool        `json:"reconnect,omitempty"`
	ProxyPort int         `json:"proxyPort,omitempty"`
	Interface string      `json:"interface,omitempty"`
}

func (s ConnectionSettings) validate(tunAllowed bool) error {
	if s.Mode != "" && s.Mode != "proxy" && s.Mode != "tun" {
		return errors.New("Неизвестный режим соединения")
	}
	if s.Mode == "tun" && !tunAllowed {
		return errors.New("Для TUN запустите системную службу с --tun; интерфейс не требует root")
	}
	if s.MTU != 0 && (s.MTU < 1280 || s.MTU > 9000) {
		return errors.New("MTU должен быть от 1280 до 9000")
	}
	if s.ProxyPort != 0 && (s.ProxyPort < 1024 || s.ProxyPort > 65535) {
		return errors.New("Порт прокси должен быть от 1024 до 65535")
	}
	if s.RouteMode != "" && s.RouteMode != "global" && s.RouteMode != "rules" {
		return errors.New("Неизвестный режим маршрутизации")
	}
	if len(s.Rules) > 500 {
		return errors.New("Не более 500 правил")
	}
	if s.Interface != "" {
		if len(s.Interface) > 64 {
			return errors.New("Некорректное имя интерфейса")
		}
		if _, err := net.InterfaceByName(s.Interface); err != nil {
			return errors.New("Исходящий интерфейс не найден")
		}
	}
	return nil
}
func compileRule(r RouteRule) (map[string]any, error) {
	result := map[string]any{"action": "route", "outbound": r.Action}
	if r.Action == "block" {
		result = map[string]any{"action": "reject"}
	} else if r.Action != "direct" && r.Action != "proxy" {
		return nil, errors.New("Правило должно направлять трафик напрямую, в прокси или блокировать")
	}
	value := strings.ToLower(strings.TrimSpace(r.Value))
	if value == "" || len(value) > 1024 {
		return nil, errors.New("Пустое или слишком длинное правило")
	}
	switch r.Type {
	case "cidr":
		if _, _, err := net.ParseCIDR(value); err != nil {
			return nil, errors.New("Некорректная CIDR-сеть")
		}
		result["ip_cidr"] = []string{value}
	case "domain":
		value = strings.TrimPrefix(value, ".")
		if len(value) > 253 || !strings.Contains(value, ".") {
			return nil, errors.New("Исключение должно быть доменом или CIDR")
		}
		for _, label := range strings.Split(value, ".") {
			if len(label) < 1 || len(label) > 63 || strings.HasPrefix(label, "-") || strings.HasSuffix(label, "-") {
				return nil, errors.New("Некорректный домен")
			}
			for _, c := range label {
				if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '-') {
					return nil, errors.New("Используйте ASCII-домен или punycode")
				}
			}
		}
		result["domain_suffix"] = []string{value}
	case "process":
		value = strings.TrimSpace(r.Value)
		if strings.ContainsAny(value, "\x00\r\n") {
			return nil, errors.New("Некорректное имя процесса")
		}
		if strings.HasPrefix(value, "/") {
			result["process_path"] = []string{value}
		} else {
			result["process_name"] = []string{value}
		}
	default:
		return nil, errors.New("Неизвестный тип правила")
	}
	return result, nil
}
func dnsServer(value, tag, detour string) (map[string]any, error) {
	if value == "" {
		value = "https://1.1.1.1/dns-query"
	}
	if value == "local" {
		if detour == "proxy" {
			return nil, errors.New("Для удалённого DNS выберите HTTPS, TLS, UDP или TCP сервер; local допустим для прямых правил")
		}
		return map[string]any{"type": "local", "tag": tag}, nil
	}
	if net.ParseIP(value) != nil {
		value = "udp://" + net.JoinHostPort(value, "53")
	}
	u, err := url.Parse(value)
	if err != nil || u.User != nil || u.Hostname() == "" || u.RawQuery != "" || u.Fragment != "" {
		return nil, errors.New("Некорректный DNS-сервер")
	}
	if net.ParseIP(u.Hostname()) == nil {
		return nil, errors.New("Для bootstrap DNS задайте IP сервера, а имя TLS — настройкой сервера")
	}
	if u.Scheme != "https" && u.Scheme != "tls" && u.Scheme != "udp" && u.Scheme != "tcp" {
		return nil, errors.New("DNS: доступны HTTPS, TLS, UDP и TCP")
	}
	result := map[string]any{"type": u.Scheme, "tag": tag, "server": u.Hostname(), "detour": detour}
	if u.Port() != "" {
		port, err := strconv.Atoi(u.Port())
		if err != nil || port < 1 || port > 65535 {
			return nil, errors.New("Некорректный порт DNS")
		}
		result["server_port"] = port
	}
	if u.Scheme == "https" && u.Path != "" {
		result["path"] = u.Path
	} else if u.Path != "" && u.Path != "/" {
		return nil, errors.New("Путь допустим только для DoH")
	}
	return result, nil
}
func buildConfig(raw string, tun bool, interfaceName string, s ConnectionSettings) (map[string]any, error) {
	out, err := outbound(raw)
	if err != nil {
		return nil, err
	}
	if err = resolveEndpoint(out); err != nil {
		return nil, err
	}
	if s.MTU == 0 {
		s.MTU = 1400
	}
	if s.ProxyPort == 0 {
		s.ProxyPort = 2080
	}
	if s.Interface != "" {
		interfaceName = s.Interface
	}
	if s.Fragment {
		tls, ok := out["tls"].(map[string]any)
		if !ok {
			return nil, errors.New("Фрагментация доступна только для TLS-соединений")
		}
		tls["fragment"] = true
	}
	inbound := map[string]any{"type": "mixed", "tag": "local", "listen": "127.0.0.1", "listen_port": s.ProxyPort}
	inbounds := []any{inbound}
	if tun {
		addresses := []string{"172.28.0.1/30"}
		if s.IPv6 == nil || *s.IPv6 {
			addresses = append(addresses, "fdfe:7665:6c75::1/126")
		}
		inbounds = append(inbounds, map[string]any{"type": "tun", "tag": "tun", "interface_name": "velum0", "address": addresses, "mtu": s.MTU, "auto_route": true, "strict_route": true})
	}
	rules := []any{map[string]any{"action": "sniff"}, map[string]any{"protocol": "dns", "action": "hijack-dns"}}
	dnsRules := []any{}
	if s.RouteMode == "rules" {
		for _, rule := range s.Rules {
			r, e := compileRule(rule)
			if e != nil {
				return nil, e
			}
			rules = append(rules, r)
			if rule.Action == "direct" && rule.Type == "domain" {
				dnsRules = append(dnsRules, map[string]any{"domain_suffix": []string{strings.TrimPrefix(strings.ToLower(strings.TrimSpace(rule.Value)), ".")}, "action": "route", "server": "direct-dns"})
			}
		}
	}
	route := map[string]any{"auto_detect_interface": true, "final": "proxy", "rules": rules}
	if interfaceName != "" {
		route["auto_detect_interface"] = false
		route["default_interface"] = interfaceName
	}
	remote, err := dnsServer(s.DNS, "remote", "proxy")
	if err != nil {
		return nil, err
	}
	directDNS := s.DirectDNS
	if directDNS == "" {
		directDNS = "local"
	}
	direct, err := dnsServer(directDNS, "direct-dns", "direct")
	if err != nil {
		return nil, err
	}
	return map[string]any{"log": map[string]any{"level": "info", "timestamp": true}, "inbounds": inbounds, "outbounds": []any{out, map[string]any{"type": "direct", "tag": "direct"}}, "dns": map[string]any{"servers": []any{remote, direct}, "final": "remote", "rules": dnsRules}, "route": route}, nil
}
