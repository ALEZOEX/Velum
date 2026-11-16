//go:build linux

package main

import (
	"encoding/json"
	"net/netip"
	"testing"

	"golang.org/x/sys/unix"
)

func TestTUNOwnershipPreservesSelectors(t *testing.T) {
	base := tunRule(unix.AF_INET6, linuxTUNRuleStart, linuxTUNTable, unix.FR_ACT_TO_TBL, 123456)
	key, err := base.canonical()
	mustF2(t, err)
	for name, changed := range map[string]tunObject{
		"unknown attribute": tunSetAttr(base, 100, []byte{1, 2, 3}),
		"inversion":         tunInvert(tunObject{base.Kind, append([]byte(nil), base.Wire...)}),
		"interface":         tunSetAttr(base, unix.FRA_IIFNAME, []byte("foreign0\x00")),
		"mark":              tunSetAttr(base, unix.FRA_FWMARK, tunU32(123457)),
		"mask":              tunSetAttr(base, unix.FRA_FWMASK, tunU32(1)),
		"protocol":          tunSetAttr(base, unix.FRA_PROTOCOL, []byte{250}),
		"action":            tunRule(unix.AF_INET6, linuxTUNRuleStart, linuxTUNTable, unix.FR_ACT_UNREACHABLE, 123456),
	} {
		t.Run(name, func(t *testing.T) {
			k, e := changed.canonical()
			mustF2(t, e)
			if k == key {
				t.Fatal("resource identity lost a selector")
			}
		})
	}
	for _, mask := range []uint32{1, ^uint32(0)} {
		if tunSetAttr(base, unix.FRA_FWMASK, tunU32(mask)).marked(123456) {
			t.Fatal("nonzero mask accepted as ownership")
		}
	}
	malformed := tunObject{"rule", append(append([]byte(nil), base.Wire...), base.Wire[12:]...)}
	if _, e := malformed.canonical(); e == nil {
		t.Fatal("duplicate attributes accepted")
	}
}
func TestTUNOwnershipRouteIdentity(t *testing.T) {
	base := tunRoute(netip.MustParsePrefix("::/0"), 12, 123456)
	key, e := base.canonical()
	mustF2(t, e)
	cache := make([]byte, 32)
	tunEndian.PutUint32(cache, 99)
	cached := tunSetAttr(base, unix.RTA_CACHEINFO, cache)
	k, e := cached.canonical()
	mustF2(t, e)
	if k != key {
		t.Fatal("use counters changed identity")
	}
	tunEndian.PutUint32(cache[8:], 10)
	k, e = tunSetAttr(base, unix.RTA_CACHEINFO, cache).canonical()
	mustF2(t, e)
	if k == key {
		t.Fatal("expiry change silently ignored")
	}
	for _, changed := range []tunObject{tunSetAttr(base, unix.RTA_PRIORITY, tunU32(123457)), tunSetAttr(base, unix.RTA_OIF, tunU32(13)), tunSetAttr(base, 100, []byte{1})} {
		k, e := changed.canonical()
		mustF2(t, e)
		if k == key {
			t.Fatal("route attributes lost")
		}
	}
}
func TestTUNJournalRejectsAmbiguity(t *testing.T) {
	original := tunJournal{Version: 1, Boot: "boot", Namespace: "ns", Session: "00112233445566778899aabbccddeeff", Mark: 123456, Attempt: 1, Objects: []tunObject{tunRule(unix.AF_INET, linuxTUNRuleStart, linuxTUNTable, unix.FR_ACT_TO_TBL, 123456)}}
	original.Hash = tunPlanHash(original.Objects)
	marshal := func(j tunJournal) []byte { b, e := json.Marshal(j); mustF2(t, e); return b }
	if _, e := decodeTUNJournal(marshal(original), "ns", "boot"); e != nil {
		t.Fatal(e)
	}
	for name, modify := range map[string]func(*tunJournal){
		"wrong boot":       func(j *tunJournal) { j.Boot = "other" },
		"wrong namespace":  func(j *tunJournal) { j.Namespace = "other" },
		"invalid session":  func(j *tunJournal) { j.Session = "zz112233445566778899aabbccddeeff" },
		"negative attempt": func(j *tunJournal) { j.Attempt = -1 },
		"invalid attempt":  func(j *tunJournal) { j.Attempt = 2 },
		"corrupt hash":     func(j *tunJournal) { j.Hash = "wrong" },
		"unmarked plan":    func(j *tunJournal) { j.Mark++ },
		"short payload":    func(j *tunJournal) { j.Objects = []tunObject{{"rule", []byte{1}}}; j.Hash = tunPlanHash(j.Objects) },
	} {
		t.Run(name, func(t *testing.T) {
			j := original
			modify(&j)
			if _, e := decodeTUNJournal(marshal(j), "ns", "boot"); e == nil {
				t.Fatal("ambiguous journal accepted")
			}
		})
	}
	if _, e := decodeTUNJournal(append(marshal(original), []byte(" {}")...), "ns", "boot"); e == nil {
		t.Fatal("trailing JSON accepted")
	}
}
func TestTUNPlanExcludesOnlyEndpoints(t *testing.T) {
	for _, entry := range []struct{ base, excluded, inside, outside string }{
		{"0.0.0.0/0", "192.0.2.5/32", "192.0.2.6", "192.0.2.5"},
		{"::/0", "2001:db8::5/128", "2001:db8::6", "2001:db8::5"},
	} {
		ranges := subtractTUNPrefix(netip.MustParsePrefix(entry.base), netip.MustParsePrefix(entry.excluded))
		contains := func(s string) bool {
			for _, p := range ranges {
				if p.Contains(netip.MustParseAddr(s)) {
					return true
				}
			}
			return false
		}
		if !contains(entry.inside) || contains(entry.outside) {
			t.Fatal("endpoint subtraction changed traffic routing")
		}
	}
}
