//go:build linux

package main

import (
	"bytes"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"net/netip"
	"sort"

	"github.com/sagernet/netlink/nl"
	"golang.org/x/sys/unix"
)

// Keep the complete netlink payload: the pinned netlink.Rule decoder drops
// action, protocol and unknown attributes, so it cannot prove exact ownership.
type tunObject struct {
	Kind string
	Wire []byte
}

const tunProtocol = 251 // Application convention, not an OS reservation.
var tunEndian = binary.NativeEndian

func tunU32(v uint32) []byte { b := make([]byte, 4); tunEndian.PutUint32(b, v); return b }
func tunAttr(body []byte, kind uint16, value []byte) []byte {
	return append(body, nl.NewRtAttr(int(kind), value).Serialize()...)
}
func tunAttrs(body []byte) (map[uint16][]byte, error) {
	if len(body) < 12 {
		return nil, errors.New("short netlink payload")
	}
	attrs, err := nl.ParseRouteAttr(body[12:])
	if err != nil {
		return nil, err
	}
	result := map[uint16][]byte{}
	for _, a := range attrs {
		if _, ok := result[a.Attr.Type]; ok {
			return nil, fmt.Errorf("duplicate netlink attribute %d", a.Attr.Type)
		}
		result[a.Attr.Type] = a.Value
	}
	return result, nil
}
func tunValue(attrs map[uint16][]byte, key uint16) uint32 {
	b := attrs[key]
	if len(b) == 4 {
		return tunEndian.Uint32(b)
	}
	return 0
}
func (o tunObject) canonical() (string, error) {
	a, err := tunAttrs(o.Wire)
	if err != nil {
		return "", err
	}
	h := append([]byte(nil), o.Wire[:12]...)
	// Only kernel-maintained rule resolution flags are volatile. All creator
	// flags, selectors, actions, protocol and unknown attributes stay in identity.
	if o.Kind == "rule" {
		flags := tunEndian.Uint32(h[8:])
		tunEndian.PutUint32(h[8:], flags&^uint32(4|8|16))
		h[5], h[6] = 0, 0
		if _, ok := a[unix.FRA_TABLE]; !ok {
			a[unix.FRA_TABLE] = tunU32(uint32(h[4]))
		}
		// Newer kernels materialize full port masks for a port-range selector.
		// Normalize only that implicit all-bits mask; preserve any other mask.
		for _, pair := range [][2]uint16{{unix.FRA_DPORT_RANGE, 29}, {unix.FRA_SPORT_RANGE, 28}} {
			if _, ok := a[pair[0]]; ok {
				if _, ok := a[pair[1]]; !ok {
					a[pair[1]] = []byte{255, 255}
				}
			}
		}
		for _, key := range []uint16{unix.FRA_SUPPRESS_PREFIXLEN, unix.FRA_SUPPRESS_IFGROUP} {
			if _, ok := a[key]; !ok {
				a[key] = tunU32(^uint32(0))
			}
		}
	} else if o.Kind == "route" {
		// Cache counters are observations, not route selectors. Expiry/error
		// changes are retained and therefore fail identity matching.
		if cache, ok := a[unix.RTA_CACHEINFO]; ok && len(cache) == 32 && tunEndian.Uint32(cache[8:12]) == 0 && tunEndian.Uint32(cache[12:16]) == 0 {
			delete(a, unix.RTA_CACHEINFO)
		}
		if h[1] == 0 {
			delete(a, unix.RTA_DST)
		}
		if h[0] == unix.AF_INET6 {
			if _, ok := a[unix.RTA_PREF]; !ok {
				a[unix.RTA_PREF] = []byte{0}
			}
		}
	} else {
		return "", errors.New("unknown resource kind")
	}
	if _, ok := a[unix.RTA_TABLE]; !ok {
		a[unix.RTA_TABLE] = tunU32(uint32(h[4]))
	}
	h[4] = 0 // Kernel uses RT_TABLE_COMPAT for extended route tables; RTA_TABLE is authoritative.
	if o.Kind == "rule" {
		delete(a, unix.FRA_PAD)
	} else {
		delete(a, unix.RTA_PAD)
	} // alignment only
	keys := make([]int, 0, len(a))
	for k := range a {
		keys = append(keys, int(k))
	}
	sort.Ints(keys)
	b := append([]byte(nil), h...)
	for _, k := range keys {
		b = tunAttr(b, uint16(k), a[uint16(k)])
	}
	return o.Kind + "/" + hex.EncodeToString(b), nil
}
func (o tunObject) marked(mark uint32) bool {
	a, err := tunAttrs(o.Wire)
	if err != nil {
		return false
	}
	if o.Kind == "rule" {
		return bytes.Equal(a[unix.FRA_PROTOCOL], []byte{tunProtocol}) && tunValue(a, unix.FRA_FWMARK) == mark && bytes.Equal(a[unix.FRA_FWMASK], tunU32(0))
	}
	return o.Kind == "route" && o.Wire[5] == tunProtocol && tunValue(a, unix.RTA_TABLE) == linuxTUNTable && tunValue(a, unix.RTA_PRIORITY) == mark
}
func tunExecute(req *nl.NetlinkRequest, response uint16) ([][]byte, error) {
	socket, e := nl.GetNetlinkSocketAt(-1, -1, unix.NETLINK_ROUTE)
	if e != nil {
		return nil, e
	}
	defer socket.Close()
	timeout := unix.Timeval{Sec: 2}
	if e = socket.SetSendTimeout(&timeout); e != nil {
		return nil, e
	}
	if e = socket.SetReceiveTimeout(&timeout); e != nil {
		return nil, e
	}
	req.Sockets = map[int]*nl.SocketHandle{unix.NETLINK_ROUTE: {Socket: socket}}
	return req.Execute(unix.NETLINK_ROUTE, response)
}
func tunDump(kind string, family int) ([]tunObject, error) {
	typ, response := unix.RTM_GETRULE, uint16(unix.RTM_NEWRULE)
	if kind == "route" {
		typ, response = unix.RTM_GETROUTE, unix.RTM_NEWROUTE
	}
	req := nl.NewNetlinkRequest(typ, unix.NLM_F_DUMP|unix.NLM_F_REQUEST)
	req.AddRawData([]byte{byte(family), 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0})
	bodies, err := tunExecute(req, response)
	if err != nil {
		return nil, err
	}
	result := make([]tunObject, 0, len(bodies))
	for _, b := range bodies {
		result = append(result, tunObject{kind, b})
	}
	return result, nil
}
func tunMutate(o tunObject, add bool) error {
	typ := unix.RTM_DELRULE
	flags := unix.NLM_F_ACK
	if o.Kind == "route" {
		typ = unix.RTM_DELROUTE
	}
	if add {
		flags |= unix.NLM_F_CREATE | unix.NLM_F_EXCL
		if o.Kind == "rule" {
			typ = unix.RTM_NEWRULE
		} else {
			typ = unix.RTM_NEWROUTE
		}
	}
	req := nl.NewNetlinkRequest(typ, flags)
	req.AddRawData(o.Wire)
	_, err := tunExecute(req, 0)
	return err
}
func tunRule(family, priority, table, action int, mark uint32) tunObject {
	b := make([]byte, 12)
	b[0], b[7] = byte(family), byte(action)
	if table < 256 {
		b[4] = byte(table)
	}
	for _, a := range []struct {
		k uint16
		v []byte
	}{
		{unix.FRA_PRIORITY, tunU32(uint32(priority))}, {unix.FRA_TABLE, tunU32(uint32(table))},
		{unix.FRA_FWMARK, tunU32(mark)}, {unix.FRA_FWMASK, tunU32(0)}, {unix.FRA_PROTOCOL, []byte{tunProtocol}},
		{unix.FRA_SUPPRESS_PREFIXLEN, tunU32(^uint32(0))}, {unix.FRA_SUPPRESS_IFGROUP, tunU32(^uint32(0))},
	} {
		b = tunAttr(b, a.k, a.v)
	}
	return tunObject{"rule", b}
}
func tunSetAttr(o tunObject, k uint16, v []byte) tunObject {
	a, _ := tunAttrs(o.Wire)
	a[k] = v
	b := append([]byte(nil), o.Wire[:12]...)
	keys := make([]int, 0, len(a))
	for key := range a {
		keys = append(keys, int(key))
	}
	sort.Ints(keys)
	for _, key := range keys {
		b = tunAttr(b, uint16(key), a[uint16(key)])
	}
	o.Wire = b
	return o
}
func tunPrefix(o tunObject, p netip.Prefix, src bool) tunObject {
	pos, key := 1, uint16(unix.FRA_DST)
	if src {
		pos, key = 2, unix.FRA_SRC
	}
	o.Wire[pos] = byte(p.Bits())
	return tunSetAttr(o, key, p.Addr().AsSlice())
}
func tunInvert(o tunObject) tunObject { tunEndian.PutUint32(o.Wire[8:], 2); return o }
func tunRoute(p netip.Prefix, index int, mark uint32) tunObject {
	b := make([]byte, 12)
	b[0] = unix.AF_INET
	if p.Addr().Is6() {
		b[0] = unix.AF_INET6
	}
	b[1], b[5], b[7] = byte(p.Bits()), tunProtocol, unix.RTN_UNICAST
	b = tunAttr(b, unix.RTA_TABLE, tunU32(linuxTUNTable))
	b = tunAttr(b, unix.RTA_OIF, tunU32(uint32(index)))
	b = tunAttr(b, unix.RTA_PRIORITY, tunU32(mark))
	if p.Bits() != 0 {
		b = tunAttr(b, unix.RTA_DST, p.Addr().AsSlice())
	}
	if p.Addr().Is6() {
		b = tunAttr(b, unix.RTA_PREF, []byte{0})
	}
	return tunObject{"route", b}
}
