package main

import (
	"context"
	"crypto/rand"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"net/netip"
	"os"
	"sort"
	"strconv"
	"strings"
	"time"

	"golang.org/x/net/dns/dnsmessage"
)

type endpointAnswer struct {
	IPs []netip.Addr
	TTL time.Duration
}
type endpointLookupFunc func(context.Context, string) (endpointAnswer, error)

// Use the configured system DNS stub/upstreams, not an unrelated public service.
// No core is allowed to re-resolve a transport name behind the ownership model.
func lookupEndpointDNS(ctx context.Context, host string) (endpointAnswer, error) {
	if ip, e := netip.ParseAddr(host); e == nil {
		return endpointAnswer{IPs: []netip.Addr{ip.Unmap()}}, nil
	}
	if data, e := os.ReadFile("/etc/hosts"); e == nil {
		if len(data) > 1<<20 {
			return endpointAnswer{}, errors.New("endpoint hosts file exceeds limit")
		}
		var ips []netip.Addr
		for _, line := range strings.Split(string(data), "\n") {
			fields := strings.Fields(strings.SplitN(line, "#", 2)[0])
			if len(fields) < 2 {
				continue
			}
			ip, e := netip.ParseAddr(fields[0])
			if e != nil {
				continue
			}
			for _, name := range fields[1:] {
				if strings.EqualFold(strings.TrimSuffix(name, "."), strings.TrimSuffix(host, ".")) {
					ips = append(ips, ip.Unmap())
					break
				}
			}
		}
		if len(ips) > 0 {
			return endpointAnswer{IPs: sortEndpointIPs(ips), TTL: 30 * time.Second}, nil
		}
	}
	data, e := os.ReadFile("/etc/resolv.conf")
	if e != nil {
		return endpointAnswer{}, fmt.Errorf("endpoint DNS config: %w", e)
	}
	if len(data) > 65536 {
		return endpointAnswer{}, errors.New("endpoint resolver config exceeds limit")
	}
	var servers, search []string
	ndots := 1
	for _, line := range strings.Split(string(data), "\n") {
		f := strings.Fields(strings.SplitN(strings.SplitN(line, "#", 2)[0], ";", 2)[0])
		if len(f) < 2 {
			continue
		}
		switch f[0] {
		case "nameserver":
			if _, e := netip.ParseAddr(f[1]); e == nil && len(servers) < 3 {
				servers = append(servers, net.JoinHostPort(f[1], "53"))
			}
		case "search", "domain":
			search = f[1:]
			if len(search) > 6 {
				search = search[:6]
			}
		case "options":
			for _, o := range f[1:] {
				if strings.HasPrefix(o, "ndots:") {
					if n, e := strconv.Atoi(strings.TrimPrefix(o, "ndots:")); e == nil && n >= 0 && n <= 15 {
						ndots = n
					}
				}
			}
		}
	}
	if len(servers) == 0 {
		return endpointAnswer{}, errors.New("endpoint DNS: no configured numeric nameserver")
	}
	var names []string
	absolute := strings.TrimSuffix(host, ".") + "."
	if strings.HasSuffix(host, ".") || strings.Count(host, ".") >= ndots {
		names = append(names, absolute)
	}
	if !strings.HasSuffix(host, ".") {
		for _, suffix := range search {
			names = append(names, strings.TrimSuffix(host, ".")+"."+strings.TrimSuffix(suffix, ".")+".")
		}
	}
	if len(names) == 0 || names[0] != absolute {
		names = append(names, absolute)
	}
	var failures []error
	for _, name := range names {
		for _, server := range servers {
			answer, e := lookupEndpointServer(ctx, server, name)
			if e == nil {
				return answer, nil
			}
			failures = append(failures, e)
			if ctx.Err() != nil {
				return endpointAnswer{}, ctx.Err()
			}
		}
	}
	return endpointAnswer{}, fmt.Errorf("endpoint DNS: %w", errors.Join(failures...))
}
func sortEndpointIPs(ips []netip.Addr) []netip.Addr {
	set := map[netip.Addr]bool{}
	for _, ip := range ips {
		set[ip.Unmap()] = true
	}
	result := make([]netip.Addr, 0, len(set))
	for ip := range set {
		result = append(result, ip)
	}
	sort.Slice(result, func(i, j int) bool {
		if result[i].Is4() != result[j].Is4() {
			return result[i].Is4()
		}
		return result[i].Less(result[j])
	})
	return result
}
func lookupEndpointServer(ctx context.Context, server, host string) (endpointAnswer, error) {
	var answer endpointAnswer
	for _, kind := range []dnsmessage.Type{dnsmessage.TypeA, dnsmessage.TypeAAAA} {
		ips, ttl, e := lookupEndpointType(ctx, server, host, kind, map[string]bool{})
		if e != nil {
			return endpointAnswer{}, e
		} // An incomplete family must not invalidate a still-valid pin.
		if len(ips) > 0 {
			answer.IPs = append(answer.IPs, ips...)
			if len(answer.IPs) == len(ips) || ttl < answer.TTL {
				answer.TTL = ttl
			}
		}
	}
	if len(answer.IPs) == 0 {
		return endpointAnswer{}, errors.New("DNS has no A/AAAA addresses")
	}
	answer.IPs = sortEndpointIPs(answer.IPs)
	return answer, nil
}
func lookupEndpointType(ctx context.Context, server, host string, kind dnsmessage.Type, visited map[string]bool) ([]netip.Addr, time.Duration, error) {
	host = strings.ToLower(strings.TrimSuffix(host, ".")) + "."
	if visited[host] || len(visited) >= 8 {
		return nil, 0, errors.New("DNS CNAME cycle/depth limit")
	}
	visited[host] = true
	name, e := dnsmessage.NewName(host)
	if e != nil {
		return nil, 0, e
	}
	var random [2]byte
	if _, e = rand.Read(random[:]); e != nil {
		return nil, 0, e
	}
	question := dnsmessage.Question{Name: name, Type: kind, Class: dnsmessage.ClassINET}
	request := dnsmessage.Message{Header: dnsmessage.Header{ID: binary.BigEndian.Uint16(random[:]), RecursionDesired: true}, Questions: []dnsmessage.Question{question}}
	reply, e := endpointDNSExchange(ctx, server, request)
	if e != nil {
		return nil, 0, e
	}
	if reply.RCode != dnsmessage.RCodeSuccess {
		name := reply.RCode.String()
		if reply.RCode == dnsmessage.RCodeNameError {
			name = "NXDOMAIN"
		}
		if reply.RCode == dnsmessage.RCodeServerFailure {
			name = "SERVFAIL"
		}
		return nil, 0, fmt.Errorf("DNS %s", name)
	}
	// Accept addresses only for this question or its bounded CNAME chain.
	current := host
	ttl := time.Duration(1<<63 - 1)
	for depth := 0; depth < 8; depth++ {
		var ips []netip.Addr
		target := ""
		for _, r := range reply.Answers {
			if r.Header.Class != dnsmessage.ClassINET || !strings.EqualFold(r.Header.Name.String(), current) {
				continue
			}
			switch body := r.Body.(type) {
			case *dnsmessage.AResource:
				if kind == dnsmessage.TypeA {
					ips = append(ips, netip.AddrFrom4(body.A))
					ttl = min(ttl, time.Duration(r.Header.TTL)*time.Second)
				}
			case *dnsmessage.AAAAResource:
				if kind == dnsmessage.TypeAAAA {
					ips = append(ips, netip.AddrFrom16(body.AAAA))
					ttl = min(ttl, time.Duration(r.Header.TTL)*time.Second)
				}
			case *dnsmessage.CNAMEResource:
				target = strings.ToLower(body.CNAME.String())
				ttl = min(ttl, time.Duration(r.Header.TTL)*time.Second)
			}
		}
		if len(ips) > 0 {
			return ips, ttl, nil
		}
		if target == "" {
			if current == host {
				return nil, 0, nil
			}
			ips, t, e := lookupEndpointType(ctx, server, current, kind, visited)
			return ips, min(ttl, t), e
		}
		if target == current || visited[target] {
			return nil, 0, errors.New("DNS CNAME cycle")
		}
		current = target
	}
	return nil, 0, errors.New("DNS CNAME depth limit")
}
func endpointDNSExchange(ctx context.Context, server string, request dnsmessage.Message) (dnsmessage.Message, error) {
	ctx, cancel := context.WithTimeout(ctx, 1500*time.Millisecond)
	defer cancel()
	packet, e := request.Pack()
	if e != nil {
		return dnsmessage.Message{}, e
	}
	for _, network := range []string{"udp", "tcp"} {
		conn, e := (&net.Dialer{}).DialContext(ctx, network, server)
		if e != nil {
			return dnsmessage.Message{}, e
		}
		stop := context.AfterFunc(ctx, func() { conn.Close() })
		if deadline, ok := ctx.Deadline(); ok {
			conn.SetDeadline(deadline)
		}
		write := packet
		if network == "tcp" {
			write = append([]byte{byte(len(packet) >> 8), byte(len(packet))}, packet...)
		}
		_, e = conn.Write(write)
		var reply dnsmessage.Message
		if e == nil {
			for {
				buffer := make([]byte, 65535)
				n := 0
				if network == "tcp" {
					_, e = io.ReadFull(conn, buffer[:2])
					if e == nil {
						n = int(binary.BigEndian.Uint16(buffer))
						_, e = io.ReadFull(conn, buffer[:n])
					}
				} else {
					n, e = conn.Read(buffer)
				}
				if e != nil {
					break
				}
				var parser dnsmessage.Parser
				header, parseErr := parser.Start(buffer[:n])
				q, qerr := parser.Question()
				if parseErr != nil || qerr != nil || !header.Response || header.ID != request.ID || len(request.Questions) != 1 || q.Type != request.Questions[0].Type || q.Class != request.Questions[0].Class || !strings.EqualFold(q.Name.String(), request.Questions[0].Name.String()) {
					if network == "tcp" {
						e = errors.New("invalid DNS response identity")
						break
					}
					continue
				}
				if header.Truncated && network == "udp" {
					reply.Header = header
					break
				}
				e = reply.Unpack(buffer[:n])
				break
			}
		}
		stop()
		conn.Close()
		if e != nil {
			if ctx.Err() != nil {
				return dnsmessage.Message{}, ctx.Err()
			}
			return dnsmessage.Message{}, e
		}
		if reply.Truncated {
			if network == "udp" {
				continue
			}
			return dnsmessage.Message{}, errors.New("truncated TCP DNS response")
		}
		return reply, nil
	}
	return dnsmessage.Message{}, errors.New("DNS exchange failed")
}
