package main

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"net/url"
	"runtime"
	"slices"
	"sort"
	"strings"
	"time"
)

// An observation never edits live routes or core config. Only an explicit/new
// controlled connection may replace a pin through the F2 lifecycle.
type endpointPin struct {
	Host                          string
	IP                            netip.Addr
	Answers                       []netip.Addr
	Interface, InterfaceSignature string
	NextDNS, Expires              time.Time
	TTL                           time.Duration
	NeedsReconnect                bool
	Message                       string
	DNSErrors                     int
	dnsFailure                    string
	ctx                           context.Context
	cancel                        context.CancelFunc
}

func managedEndpoint(tun bool, req ConnectRequest) bool {
	if req.Settings.Mode != "" {
		tun = req.Settings.Mode == "tun"
	}
	return runtime.GOOS == "linux" && tun
}
func endpointOutbound(raw string) (map[string]any, error) {
	if !isXHTTP(raw) {
		return outbound(raw)
	}
	u, e := url.Parse(raw)
	if e != nil {
		return nil, e
	}
	q := u.Query()
	q.Set("type", "tcp")
	u.RawQuery = q.Encode()
	return outbound(u.String())
}
func pinOutboundServer(out map[string]any, ip netip.Addr) {
	host, _ := out["server"].(string)
	if _, e := netip.ParseAddr(host); e != nil {
		if tls, ok := out["tls"].(map[string]any); ok {
			if _, ok := tls["server_name"]; !ok {
				tls["server_name"] = host
			}
		}
	}
	out["server"] = ip.String()
}
func safeEndpointIPs(ips []netip.Addr) ([]netip.Addr, error) {
	ips = sortEndpointIPs(ips)
	for _, ip := range ips {
		if !ip.IsValid() || ip.IsUnspecified() || ip.IsMulticast() || ip.Zone() != "" || netip.MustParsePrefix("172.28.0.0/30").Contains(ip) || netip.MustParsePrefix("fdfe:7665:6c75::/126").Contains(ip) {
			return nil, errors.New("DNS endpoint содержит недопустимый адрес или адрес собственной сети TUN")
		}
	}
	if len(ips) == 0 {
		return nil, errors.New("DNS endpoint не вернул адреса")
	}
	return ips, nil
}
func endpointInterfaceSignature(name string) (string, error) {
	iface, e := net.InterfaceByName(name)
	if e != nil {
		return "", e
	}
	if iface.Flags&net.FlagUp == 0 || strings.HasPrefix(strings.ToLower(name), "velum") {
		return "", errors.New("исходящий интерфейс выключен или является TUN Velum")
	}
	addrs, e := iface.Addrs()
	if e != nil {
		return "", e
	}
	var values []string
	for _, a := range addrs {
		values = append(values, a.String())
	}
	sort.Strings(values)
	return fmt.Sprintf("%d/%s", iface.Index, strings.Join(values, ",")), nil
}
func endpointPollDelay(ttl time.Duration) time.Duration {
	return max(5*time.Second, min(ttl, 5*time.Minute))
}
func (s *service) prepareEndpoint(ctx context.Context, req ConnectRequest) (*endpointPin, error) {
	if !managedEndpoint(s.tun, req) {
		return nil, nil
	}
	if e := req.Settings.validate(s.tun); e != nil {
		return nil, e
	}
	out, e := endpointOutbound(req.URI)
	if e != nil {
		return nil, e
	}
	host, _ := out["server"].(string)
	s.mu.Lock()
	lookup := s.endpointLookup
	if lookup == nil {
		lookup = lookupEndpointDNS
	}
	iface := s.interfaceName
	var previous netip.Addr
	probe := ""
	if s.tunActive && s.endpoint != nil {
		probe = s.endpoint.IP.String()
		if strings.EqualFold(s.endpoint.Host, host) {
			previous = s.endpoint.IP
		}
	}
	s.mu.Unlock()
	if req.Settings.Interface != "" {
		iface = req.Settings.Interface
	}
	var answer endpointAnswer
	ip, ipErr := netip.ParseAddr(host)
	if ipErr == nil {
		answer.IPs = []netip.Addr{ip.Unmap()}
	} else {
		resolveCtx, cancel := context.WithTimeout(ctx, 3*time.Second)
		answer, e = lookup(resolveCtx, host)
		cancel()
		if e != nil {
			return nil, fmt.Errorf("Не удалось обновить DNS endpoint: %w", e)
		}
	}
	answer.IPs, e = safeEndpointIPs(answer.IPs)
	if e != nil {
		return nil, e
	}
	// On a deliberate reconnect, try the next advertised address. A DNS
	// observation alone never changes the address of a running transport.
	start := (slices.Index(answer.IPs, previous) + 1) % len(answer.IPs)
	selected := answer.IPs[start]
	if iface == "" {
		for offset := range answer.IPs {
			selected = answer.IPs[(start+offset)%len(answer.IPs)]
			iface, e = detectOutboundInterface(selected.String())
			if e == nil {
				break
			}
			// The existing TUN can mask the route to a prospective endpoint.
			// Its established transport still has an exact physical exception.
			if probe != "" && probe != selected.String() {
				iface, e = detectOutboundInterface(probe)
				if e == nil {
					break
				}
			}
		}
		if e != nil {
			return nil, fmt.Errorf("Безопасный интерфейс endpoint не определён: %w", e)
		}
	}
	signature, e := endpointInterfaceSignature(iface)
	if e != nil {
		return nil, e
	}
	pinCtx, cancel := context.WithCancel(context.Background())
	pin := &endpointPin{Host: host, IP: selected, Answers: append([]netip.Addr(nil), answer.IPs...), Interface: iface, InterfaceSignature: signature, TTL: answer.TTL, ctx: pinCtx, cancel: cancel}
	pin.NextDNS = time.Now().Add(endpointPollDelay(answer.TTL))
	pin.Expires = time.Now().Add(answer.TTL)
	if ipErr == nil {
		pin.NextDNS = time.Time{}
		pin.Expires = time.Time{}
	}
	return pin, nil
}
func (s *service) observeEndpoint(ctx context.Context) {
	s.mu.Lock()
	pin := s.endpoint
	if pin == nil || s.cmd == nil || s.state != "running" {
		s.mu.Unlock()
		return
	}
	iface, signature, ip := pin.Interface, pin.InterfaceSignature, pin.IP
	host, next := pin.Host, pin.NextDNS
	lookup := s.endpointLookup
	if lookup == nil {
		lookup = lookupEndpointDNS
	}
	explicit := s.interfaceName != "" || s.desired != nil && s.desired.Settings.Interface != ""
	s.mu.Unlock()
	message := ""
	currentSignature, e := endpointInterfaceSignature(iface)
	if e != nil || currentSignature != signature {
		message = "Исходящий интерфейс или его адрес изменился; переподключитесь. TUN и прежний endpoint сохранены"
	}
	if message == "" && !explicit {
		current, e := detectOutboundInterface(ip.String())
		if e != nil || current != iface {
			message = "Маршрут к endpoint изменился; переподключитесь. TUN и прежний endpoint сохранены"
		}
	}
	var answer endpointAnswer
	var dnsErr error
	queried := message == "" && !next.IsZero() && !time.Now().Before(next)
	if queried {
		dnsCtx, cancel := context.WithTimeout(pin.ctx, 2*time.Second)
		stop := context.AfterFunc(ctx, cancel)
		answer, dnsErr = lookup(dnsCtx, host)
		stop()
		cancel()
		if dnsErr == nil {
			answer.IPs, dnsErr = safeEndpointIPs(answer.IPs)
		}
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.endpoint != pin || s.state != "running" || s.deadCoreLocked() != "" || pin.ctx.Err() != nil || ctx.Err() != nil {
		return
	}
	if queried {
		if dnsErr != nil {
			pin.DNSErrors++
			pin.dnsFailure = fmt.Sprintf("DNS endpoint недоступен: %v. Используется прежний закреплённый IP; маршруты сохранены", dnsErr)
			pin.NextDNS = time.Now().Add(min(time.Minute, 5*time.Second*time.Duration(1<<min(pin.DNSErrors, 4))))
			s.verified = false
		} else {
			pin.DNSErrors = 0
			pin.Answers = append([]netip.Addr(nil), answer.IPs...)
			pin.TTL = answer.TTL
			pin.Expires = time.Now().Add(answer.TTL)
			pin.NextDNS = time.Now().Add(endpointPollDelay(answer.TTL))
			pin.dnsFailure = ""
		}
	}
	if message == "" && !slices.Contains(pin.Answers, pin.IP) {
		message = "IP endpoint изменился; требуется переподключение. Прежний TUN сохранён, новые IP не используются"
	}
	pin.NeedsReconnect = message != ""
	pin.Message = strings.TrimSpace(message + " " + pin.dnsFailure)
	if pin.NeedsReconnect {
		s.verified = false
	}
	s.publishStatusLocked()
}
func (p *endpointPin) status() map[string]any {
	if p == nil {
		return nil
	}
	values := make([]string, len(p.Answers))
	for i, ip := range p.Answers {
		values[i] = ip.String()
	}
	var expires any
	if !p.Expires.IsZero() {
		expires = p.Expires
	}
	return map[string]any{"host": p.Host, "ip": p.IP.String(), "answers": values, "interface": p.Interface, "needsReconnect": p.NeedsReconnect, "dnsErrors": p.DNSErrors, "message": p.Message, "expiresAt": expires}
}
