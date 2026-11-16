//go:build linux

package main

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func testF2DataPlane(t *testing.T, baseline []string, newService func() *service) {
	proxy, e := net.Listen("tcp4", "127.0.0.1:0")
	mustF2(t, e)
	defer proxy.Close()
	var tcpCount, dnsCount atomic.Int32
	go func() {
		for {
			c, e := proxy.Accept()
			if e != nil {
				return
			}
			go f2SOCKS(c, &tcpCount, &dnsCount)
		}
	}()
	s := newService()
	s.interfaceName = "lo"
	defer s.stop()
	req := ConnectRequest{URI: "socks5://" + proxy.Addr().String(), Settings: ConnectionSettings{Mode: "tun", DNS: "udp://198.18.0.53:5353"}}
	mustF2(t, s.connectRequest(req))
	for _, target := range []struct{ network, address string }{{"tcp4", "198.18.0.7:80"}, {"tcp6", "[2001:db8::7]:80"}} {
		t.Run(target.network, func(t *testing.T) {
			c, e := net.DialTimeout(target.network, target.address, 3*time.Second)
			mustF2(t, e)
			defer c.Close()
			c.SetDeadline(time.Now().Add(3 * time.Second))
			_, e = c.Write([]byte("GET / HTTP/1.1\r\nHost: f2.example\r\nConnection: close\r\n\r\n"))
			mustF2(t, e)
			b, e := io.ReadAll(c)
			mustF2(t, e)
			if !bytes.Contains(b, []byte("f2-through-tun")) {
				t.Fatalf("traffic did not reach SOCKS fixture: %s", b)
			}
		})
	}
	query := []byte{0x12, 0x34, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 2, 'f', '2', 7, 'e', 'x', 'a', 'm', 'p', 'l', 'e', 0, 0, 1, 0, 1}
	for _, target := range []struct{ network, address string }{{"udp4", "8.8.8.8:53"}, {"udp6", "[2001:4860:4860::8888]:53"}, {"tcp4", "8.8.4.4:53"}, {"tcp6", "[2001:4860:4860::8844]:53"}} {
		t.Run("dns_"+target.network, func(t *testing.T) {
			c, e := net.DialTimeout(target.network, target.address, 3*time.Second)
			mustF2(t, e)
			defer c.Close()
			c.SetDeadline(time.Now().Add(3 * time.Second))
			packet := query
			if strings.HasPrefix(target.network, "tcp") {
				packet = append([]byte{0, byte(len(query))}, query...)
			}
			_, e = c.Write(packet)
			mustF2(t, e)
			var b []byte
			if strings.HasPrefix(target.network, "tcp") {
				head := make([]byte, 2)
				_, e = io.ReadFull(c, head)
				mustF2(t, e)
				b = make([]byte, binary.BigEndian.Uint16(head))
				_, e = io.ReadFull(c, b)
			} else {
				b = make([]byte, 2048)
				var n int
				n, e = c.Read(b)
				b = b[:n]
			}
			mustF2(t, e)
			if len(b) < 12 || !bytes.Equal(b[:2], query[:2]) || !bytes.Contains(b, []byte{203, 0, 113, 77}) {
				t.Fatalf("DNS did not pass through proxy resolver: %x", b)
			}
		})
	}
	if tcpCount.Load() != 2 || dnsCount.Load() < 1 {
		t.Fatalf("fixture counts: TCP=%d DNS=%d", tcpCount.Load(), dnsCount.Load())
	}
	mustF2(t, s.stop())
	assertF2Snapshot(t, baseline)
}
func f2SOCKS(c net.Conn, tcpCount, dnsCount *atomic.Int32) {
	defer c.Close()
	c.SetDeadline(time.Now().Add(25 * time.Second))
	header := make([]byte, 2)
	if _, e := io.ReadFull(c, header); e != nil {
		return
	}
	methods := make([]byte, int(header[1]))
	if _, e := io.ReadFull(c, methods); e != nil {
		return
	}
	c.Write([]byte{5, 0})
	h := make([]byte, 4)
	if _, e := io.ReadFull(c, h); e != nil {
		return
	}
	if _, e := f2ReadSOCKSAddress(c, h[3]); e != nil {
		return
	}
	if h[1] == 1 {
		c.Write([]byte{5, 0, 0, 1, 127, 0, 0, 1, 0, 0})
		b := make([]byte, 4096)
		if _, e := c.Read(b); e != nil {
			return
		}
		tcpCount.Add(1)
		body := "f2-through-tun"
		fmt.Fprintf(c, "HTTP/1.1 200 OK\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s", len(body), body)
		return
	}
	if h[1] != 3 {
		return
	}
	udp, e := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if e != nil {
		return
	}
	defer udp.Close()
	port := udp.LocalAddr().(*net.UDPAddr).Port
	c.Write([]byte{5, 0, 0, 1, 127, 0, 0, 1, byte(port >> 8), byte(port)})
	go func() { _, _ = io.Copy(io.Discard, c); udp.Close() }()
	for {
		buffer := make([]byte, 8192)
		n, peer, e := udp.ReadFromUDP(buffer)
		if e != nil {
			return
		}
		packet := buffer[:n]
		if len(packet) < 4 {
			continue
		}
		reader := bytes.NewReader(packet[4:])
		_, e = f2ReadSOCKSAddress(reader, packet[3])
		if e != nil {
			continue
		}
		offset := len(packet) - reader.Len()
		query := packet[offset:]
		answer := f2DNSReply(query)
		if answer == nil {
			continue
		}
		dnsCount.Add(1)
		udp.WriteToUDP(append(append([]byte(nil), packet[:offset]...), answer...), peer)
	}
}
func f2ReadSOCKSAddress(r io.Reader, kind byte) ([]byte, error) {
	size := 0
	switch kind {
	case 1:
		size = 4
	case 4:
		size = 16
	case 3:
		b := make([]byte, 1)
		if _, e := io.ReadFull(r, b); e != nil {
			return nil, e
		}
		size = int(b[0])
	default:
		return nil, fmt.Errorf("SOCKS address %d", kind)
	}
	b := make([]byte, size+2)
	_, e := io.ReadFull(r, b)
	return b, e
}
func f2DNSReply(query []byte) []byte {
	if len(query) < 17 {
		return nil
	}
	pos := 12
	for {
		if pos >= len(query) {
			return nil
		}
		n := int(query[pos])
		pos++
		if n == 0 {
			break
		}
		pos += n
	}
	if pos+4 > len(query) {
		return nil
	}
	typ := binary.BigEndian.Uint16(query[pos:])
	end := pos + 4
	r := append([]byte(nil), query[:end]...)
	r[2], r[3] = 0x81, 0x80
	r[6], r[7] = 0, 1
	r[8], r[9], r[10], r[11] = 0, 0, 0, 0
	address := []byte{203, 0, 113, 77}
	if typ == 28 {
		address = net.ParseIP("2001:db8::77").To16()
	}
	r = append(r, 0xc0, 0x0c, byte(typ>>8), byte(typ), 0, 1, 0, 0, 0, 60, 0, byte(len(address)))
	return append(r, address...)
}
