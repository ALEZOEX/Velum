package main

import (
	"context"
	"encoding/binary"
	"errors"
	"io"
	"net"
	"net/netip"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"golang.org/x/net/dns/dnsmessage"
)

func endpointDNSServer(t *testing.T, handle func(dnsmessage.Message, bool) []byte) string {
	t.Helper()
	udp, e := net.ListenPacket("udp4", "127.0.0.1:0")
	if e != nil {
		t.Fatal(e)
	}
	tcp, e := net.Listen("tcp4", udp.LocalAddr().String())
	if e != nil {
		udp.Close()
		t.Fatal(e)
	}
	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		for {
			b := make([]byte, 4096)
			n, peer, e := udp.ReadFrom(b)
			if e != nil {
				return
			}
			var q dnsmessage.Message
			if q.Unpack(b[:n]) != nil {
				continue
			}
			reply := handle(q, false)
			if reply != nil {
				udp.WriteTo(reply, peer)
			}
		}
	}()
	go func() {
		defer wg.Done()
		for {
			c, e := tcp.Accept()
			if e != nil {
				return
			}
			func() {
				defer c.Close()
				c.SetDeadline(time.Now().Add(time.Second))
				var h [2]byte
				if _, e = io.ReadFull(c, h[:]); e != nil {
					return
				}
				b := make([]byte, binary.BigEndian.Uint16(h[:]))
				if _, e = io.ReadFull(c, b); e != nil {
					return
				}
				var q dnsmessage.Message
				if q.Unpack(b) != nil {
					return
				}
				reply := handle(q, true)
				if reply != nil {
					c.Write(append([]byte{byte(len(reply) >> 8), byte(len(reply))}, reply...))
				}
			}()
		}
	}()
	t.Cleanup(func() { udp.Close(); tcp.Close(); wg.Wait() })
	return udp.LocalAddr().String()
}
func endpointDNSReply(q dnsmessage.Message, ips []netip.Addr, ttl uint32) dnsmessage.Message {
	r := dnsmessage.Message{Header: dnsmessage.Header{ID: q.ID, Response: true, RecursionAvailable: true}, Questions: q.Questions}
	for _, ip := range ips {
		h := dnsmessage.ResourceHeader{Name: q.Questions[0].Name, Class: dnsmessage.ClassINET, TTL: ttl}
		if ip.Is4() && q.Questions[0].Type == dnsmessage.TypeA {
			h.Type = dnsmessage.TypeA
			r.Answers = append(r.Answers, dnsmessage.Resource{Header: h, Body: &dnsmessage.AResource{A: ip.As4()}})
		}
		if ip.Is6() && q.Questions[0].Type == dnsmessage.TypeAAAA {
			h.Type = dnsmessage.TypeAAAA
			r.Answers = append(r.Answers, dnsmessage.Resource{Header: h, Body: &dnsmessage.AAAAResource{AAAA: ip.As16()}})
		}
	}
	return r
}
func packEndpointReply(t *testing.T, r dnsmessage.Message) []byte {
	t.Helper()
	b, e := r.Pack()
	if e != nil {
		t.Error(e)
	}
	return b
}
func TestEndpointDNSRealWireDualStackTTL(t *testing.T) {
	ips := []netip.Addr{netip.MustParseAddr("2001:db8::3"), netip.MustParseAddr("192.0.2.3"), netip.MustParseAddr("192.0.2.2"), netip.MustParseAddr("192.0.2.2")}
	server := endpointDNSServer(t, func(q dnsmessage.Message, _ bool) []byte {
		ttl := uint32(20)
		if q.Questions[0].Type == dnsmessage.TypeAAAA {
			ttl = 3
		}
		return packEndpointReply(t, endpointDNSReply(q, ips, ttl))
	})
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	a, e := lookupEndpointServer(ctx, server, "endpoint.example.")
	if e != nil {
		t.Fatal(e)
	}
	if a.TTL != 3*time.Second || len(a.IPs) != 3 || a.IPs[0].String() != "192.0.2.2" || !a.IPs[2].Is6() {
		t.Fatalf("incorrect set/TTL: %+v", a)
	}
}
func TestEndpointDNSRealWireTCPFallback(t *testing.T) {
	var calls atomic.Int32
	server := endpointDNSServer(t, func(q dnsmessage.Message, tcp bool) []byte {
		r := endpointDNSReply(q, []netip.Addr{netip.MustParseAddr("192.0.2.4")}, 1)
		if !tcp {
			r.Truncated = true
			r.Answers = nil
		} else {
			calls.Add(1)
		}
		return packEndpointReply(t, r)
	})
	a, e := lookupEndpointServer(context.Background(), server, "endpoint.example.")
	if e != nil || len(a.IPs) != 1 || calls.Load() != 2 {
		t.Fatalf("TCP fallback: %+v %v calls=%d", a, e, calls.Load())
	}
}
func TestEndpointDNSNegativeAnswers(t *testing.T) {
	for _, entry := range []struct {
		code dnsmessage.RCode
		text string
	}{{dnsmessage.RCodeNameError, "NXDOMAIN"}, {dnsmessage.RCodeServerFailure, "SERVFAIL"}, {dnsmessage.RCodeSuccess, "no A/AAAA"}} {
		t.Run(entry.text, func(t *testing.T) {
			server := endpointDNSServer(t, func(q dnsmessage.Message, _ bool) []byte {
				r := endpointDNSReply(q, nil, 0)
				r.RCode = entry.code
				return packEndpointReply(t, r)
			})
			_, e := lookupEndpointServer(context.Background(), server, "endpoint.example.")
			if e == nil || !strings.Contains(e.Error(), entry.text) {
				t.Fatalf("wrong negative result: %v", e)
			}
		})
	}
}
func TestEndpointDNSCancellationIsBounded(t *testing.T) {
	received := make(chan struct{}, 1)
	server := endpointDNSServer(t, func(q dnsmessage.Message, _ bool) []byte {
		select {
		case received <- struct{}{}:
		default:
		}
		return nil
	})
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { _, e := lookupEndpointServer(ctx, server, "endpoint.example."); done <- e }()
	<-received
	cancel()
	select {
	case e := <-done:
		if !errors.Is(e, context.Canceled) {
			t.Fatalf("cancellation lost: %v", e)
		}
	case <-time.After(time.Second):
		t.Fatal("DNS ignored cancellation")
	}
}
func TestEndpointDNSCNAMEAndOwnerValidation(t *testing.T) {
	for _, cycle := range []bool{false, true} {
		name := "alias"
		if cycle {
			name = "cycle"
		}
		t.Run(name, func(t *testing.T) {
			server := endpointDNSServer(t, func(q dnsmessage.Message, _ bool) []byte {
				r := endpointDNSReply(q, nil, 0)
				alias, _ := dnsmessage.NewName("alias.example.")
				target := alias
				if cycle {
					target = q.Questions[0].Name
				}
				r.Answers = append(r.Answers, dnsmessage.Resource{Header: dnsmessage.ResourceHeader{Name: q.Questions[0].Name, Type: dnsmessage.TypeCNAME, Class: dnsmessage.ClassINET, TTL: 2}, Body: &dnsmessage.CNAMEResource{CNAME: target}})
				if !cycle && q.Questions[0].Type == dnsmessage.TypeA {
					r.Answers = append(r.Answers, dnsmessage.Resource{Header: dnsmessage.ResourceHeader{Name: alias, Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET, TTL: 10}, Body: &dnsmessage.AResource{A: [4]byte{192, 0, 2, 9}}})
				}
				if !cycle && q.Questions[0].Type == dnsmessage.TypeAAAA {
					r.Answers = nil
				} // NODATA family is not failure.
				foreign, _ := dnsmessage.NewName("unrelated.example.")
				r.Answers = append(r.Answers, dnsmessage.Resource{Header: dnsmessage.ResourceHeader{Name: foreign, Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET, TTL: 1}, Body: &dnsmessage.AResource{A: [4]byte{203, 0, 113, 99}}})
				return packEndpointReply(t, r)
			})
			a, e := lookupEndpointServer(context.Background(), server, "endpoint.example.")
			if cycle {
				if e == nil || !strings.Contains(e.Error(), "cycle") {
					t.Fatalf("CNAME loop: %v", e)
				}
			} else if e != nil || len(a.IPs) != 1 || a.IPs[0].String() != "192.0.2.9" || a.TTL != 2*time.Second {
				t.Fatalf("owner/TTL validation: %+v %v", a, e)
			}
		})
	}
}

func TestEndpointDNSRejectsInvalidTCPReply(t *testing.T) {
	for _, field := range []string{"opcode", "extra question"} {
		t.Run(field, func(t *testing.T) {
			server := endpointDNSServer(t, func(q dnsmessage.Message, tcp bool) []byte {
				r := endpointDNSReply(q, []netip.Addr{netip.MustParseAddr("192.0.2.4")}, 1)
				if !tcp {
					r.Truncated = true
				} else if field == "opcode" {
					r.OpCode = 2
				} else {
					r.Questions = append(r.Questions, q.Questions[0])
				}
				return packEndpointReply(t, r)
			})
			if _, err := lookupEndpointServer(context.Background(), server, "endpoint.example."); err == nil {
				t.Fatal("malformed reply supplied a transport pin")
			}
		})
	}
}
