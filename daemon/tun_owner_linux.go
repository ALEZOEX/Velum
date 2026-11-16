//go:build linux

package main

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/sagernet/netlink"
	"golang.org/x/sys/unix"
)

const tunStateRoot = "/run/velum-tun"
const tunMaxObjects = 2048

type tunJournal struct {
	Version   int
	Boot      string
	Namespace string
	Session   string
	Mark      uint32
	Objects   []tunObject
	Attempt   int
	Hash      string
}
type tunLease struct {
	dir       *os.File
	lock      *os.File
	namespace string
}

func tunNamespace() (string, error) {
	var s unix.Stat_t
	if e := unix.Stat("/proc/self/ns/net", &s); e != nil {
		return "", e
	}
	return fmt.Sprintf("%x-%x", s.Dev, s.Ino), nil
}
func trustedTUNFile(fd int, directory bool) error {
	var s unix.Stat_t
	if e := unix.Fstat(fd, &s); e != nil {
		return e
	}
	kind := uint32(unix.S_IFREG)
	if directory {
		kind = unix.S_IFDIR
	}
	if s.Mode&unix.S_IFMT != kind || s.Uid != 0 || s.Mode&0077 != 0 || (!directory && s.Nlink != 1) {
		return errors.New("TUN journal/lock is not a private root-owned object")
	}
	for _, name := range []string{"system.posix_acl_access", "system.posix_acl_default"} {
		_, e := unix.Fgetxattr(fd, name, nil)
		if e == nil {
			return errors.New("TUN state has an extended ACL")
		}
		if !errors.Is(e, unix.ENODATA) && !errors.Is(e, unix.ENOTSUP) {
			return e
		}
	}
	return nil
}
func acquireTUNLease() (*tunLease, error) {
	ns, e := tunNamespace()
	if e != nil {
		return nil, e
	}
	run, e := unix.Open("/run", unix.O_RDONLY|unix.O_DIRECTORY|unix.O_CLOEXEC|unix.O_NOFOLLOW, 0)
	if e != nil {
		return nil, e
	}
	defer unix.Close(run)
	var rs unix.Stat_t
	if e = unix.Fstat(run, &rs); e != nil {
		return nil, e
	}
	if rs.Uid != 0 || rs.Mode&0022 != 0 {
		return nil, errors.New("/run must be root-owned and not writable by other users")
	}
	if e = unix.Mkdirat(run, "velum-tun", 0700); e != nil && !errors.Is(e, unix.EEXIST) {
		return nil, e
	}
	base, e := unix.Openat(run, "velum-tun", unix.O_RDONLY|unix.O_DIRECTORY|unix.O_CLOEXEC|unix.O_NOFOLLOW, 0)
	if e != nil {
		return nil, e
	}
	defer unix.Close(base)
	if e = trustedTUNFile(base, true); e != nil {
		return nil, e
	}
	name := "net-" + ns
	if e = unix.Mkdirat(base, name, 0700); e != nil && !errors.Is(e, unix.EEXIST) {
		return nil, e
	}
	dir, e := unix.Openat(base, name, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_CLOEXEC|unix.O_NOFOLLOW, 0)
	if e != nil {
		return nil, e
	}
	if e = trustedTUNFile(dir, true); e != nil {
		unix.Close(dir)
		return nil, e
	}
	lock, e := unix.Openat(dir, "lock", unix.O_RDWR|unix.O_CREAT|unix.O_CLOEXEC|unix.O_NOFOLLOW|unix.O_NONBLOCK, 0600)
	if e != nil {
		unix.Close(dir)
		return nil, e
	}
	if e = trustedTUNFile(lock, false); e == nil {
		e = unix.Flock(lock, unix.LOCK_EX|unix.LOCK_NB)
	}
	if e != nil {
		unix.Close(lock)
		unix.Close(dir)
		return nil, fmt.Errorf("TUN занят другим экземпляром Velum либо журнал недоверенный: %w", e)
	}
	return &tunLease{os.NewFile(uintptr(dir), name), os.NewFile(uintptr(lock), "tun-lock"), ns}, nil
}
func (l *tunLease) close() { l.lock.Close(); l.dir.Close() }
func tunBoot() string {
	b, _ := os.ReadFile("/proc/sys/kernel/random/boot_id")
	return strings.TrimSpace(string(b))
}
func tunPlanHash(objects []tunObject) string {
	b, _ := json.Marshal(objects)
	h := sha256.Sum256(b)
	return hex.EncodeToString(h[:])
}
func (l *tunLease) write(j *tunJournal) error {
	b, e := json.Marshal(j)
	if e != nil {
		return e
	}
	if len(b) >= 1024*1024 {
		return errors.New("TUN journal plan exceeds 1 MiB; setup refused")
	}
	b = append(b, '\n')
	var random [12]byte
	if _, e = rand.Read(random[:]); e != nil {
		return e
	}
	name := ".write-" + hex.EncodeToString(random[:])
	fd, e := unix.Openat(int(l.dir.Fd()), name, unix.O_WRONLY|unix.O_CREAT|unix.O_EXCL|unix.O_CLOEXEC|unix.O_NOFOLLOW, 0600)
	if e != nil {
		return e
	}
	f := os.NewFile(uintptr(fd), name)
	defer f.Close()
	defer unix.Unlinkat(int(l.dir.Fd()), name, 0)
	if _, e = f.Write(b); e != nil {
		return e
	}
	if e = f.Sync(); e != nil {
		return e
	}
	if e = unix.Renameat(int(l.dir.Fd()), name, int(l.dir.Fd()), "journal.json"); e != nil {
		return e
	}
	return l.dir.Sync()
}
func (l *tunLease) read() (*tunJournal, error) {
	fd, e := unix.Openat(int(l.dir.Fd()), "journal.json", unix.O_RDONLY|unix.O_NONBLOCK|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
	if errors.Is(e, unix.ENOENT) {
		return nil, nil
	}
	if e != nil {
		return nil, e
	}
	f := os.NewFile(uintptr(fd), "journal")
	defer f.Close()
	if e = trustedTUNFile(fd, false); e != nil {
		return nil, e
	}
	data, e := io.ReadAll(io.LimitReader(f, 1024*1024+1))
	if e != nil {
		return nil, e
	}
	if len(data) > 1024*1024 {
		return nil, errors.New("TUN journal too large")
	}
	return decodeTUNJournal(data, l.namespace, tunBoot())
}

func decodeTUNJournal(data []byte, namespace, boot string) (*tunJournal, error) {
	var e error
	var j tunJournal
	d := json.NewDecoder(strings.NewReader(string(data)))
	d.DisallowUnknownFields()
	if e = d.Decode(&j); e != nil {
		return nil, e
	}
	if d.Decode(new(any)) != io.EOF {
		return nil, errors.New("trailing data in TUN journal")
	}
	if _, e = hex.DecodeString(j.Session); e != nil {
		return nil, errors.New("invalid TUN session identifier")
	}
	if j.Version != 1 || j.Boot == "" || j.Boot != boot || j.Namespace != namespace || len(j.Session) != 32 || j.Mark < 65536 || j.Mark > 0x7fffffff || j.Attempt < 0 || j.Attempt > len(j.Objects) || len(j.Objects) > tunMaxObjects || j.Hash != tunPlanHash(j.Objects) {
		return nil, errors.New("invalid TUN journal identity/plan; automatic recovery refused")
	}
	for _, o := range j.Objects {
		if len(o.Wire) < 12 || (o.Wire[0] != unix.AF_INET && o.Wire[0] != unix.AF_INET6) || !o.marked(j.Mark) {
			return nil, errors.New("invalid ownership marker in TUN journal")
		}
		if _, e = o.canonical(); e != nil {
			return nil, e
		}
	}
	return &j, nil
}
func tunAllObjects() ([]tunObject, error) {
	var result []tunObject
	for _, kind := range []string{"rule", "route"} {
		for _, f := range []int{unix.AF_INET, unix.AF_INET6} {
			objects, e := tunDump(kind, f)
			if e != nil {
				return nil, e
			}
			result = append(result, objects...)
		}
	}
	return result, nil
}
func (l *tunLease) recover() error {
	j, e := l.read()
	if e != nil {
		return fmt.Errorf("TUN recovery отказано: %w", e)
	}
	if j == nil {
		return nil
	}
	links, e := netlink.LinkList()
	if e != nil {
		return e
	}
	for _, link := range links {
		if link.Attrs().Name == "velum0" {
			return errors.New("TUN recovery отказано: velum0 ещё существует, владелец/держатель FD не подтверждён")
		}
	}
	current, e := tunAllObjects()
	if e != nil {
		return e
	}
	expected := map[string]tunObject{}
	for _, o := range j.Objects[:j.Attempt] {
		key, e := o.canonical()
		if e != nil {
			return e
		}
		if _, ok := expected[key]; ok {
			return errors.New("duplicate resource in TUN journal")
		}
		expected[key] = o
	}
	found := map[string]int{}
	for _, o := range current {
		if o.marked(j.Mark) {
			key, e := o.canonical()
			if e != nil {
				return e
			}
			if _, ok := expected[key]; !ok {
				return errors.New("TUN recovery conflict: session-tagged resource attributes changed; journal retained")
			}
			found[key]++
			if found[key] > 1 {
				return errors.New("TUN recovery conflict: duplicate resource identity; journal retained")
			}
		}
	}
	// Full attributes are sent in DEL, including the session marker, action and
	// selectors. Kernel matching constrains deletion even after this dump races.
	for i := j.Attempt - 1; i >= 0; i-- {
		o := j.Objects[i]
		key, _ := o.canonical()
		if found[key] == 0 {
			continue
		}
		latest, e := tunDump(o.Kind, int(o.Wire[0]))
		if e != nil {
			return e
		}
		var actual *tunObject
		for _, candidate := range latest {
			k, e := candidate.canonical()
			if e != nil {
				return e
			}
			if k == key {
				if actual != nil {
					return errors.New("TUN cleanup duplicate identity")
				}
				c := candidate
				actual = &c
			}
		}
		if actual == nil {
			continue
		}
		if e = tunMutate(*actual, false); e != nil && !errors.Is(e, unix.ESRCH) && !errors.Is(e, unix.ENOENT) {
			return e
		}
	}
	current, e = tunAllObjects()
	if e != nil {
		return e
	}
	for _, o := range current {
		if o.marked(j.Mark) {
			return errors.New("TUN cleanup not confirmed; journal retained")
		}
	}
	if e = unix.Unlinkat(int(l.dir.Fd()), "journal.json", 0); e != nil && !errors.Is(e, unix.ENOENT) {
		return e
	}
	return l.dir.Sync()
}
func recoverTUN() error {
	l, e := acquireTUNLease()
	if e != nil {
		return e
	}
	defer l.close()
	return l.recover()
}
func newTUNJournal(l *tunLease) (*tunJournal, error) {
	all, e := tunAllObjects()
	if e != nil {
		return nil, e
	}
	var id [16]byte
	var b [4]byte
	if _, e = rand.Read(id[:]); e != nil {
		return nil, e
	}
	for range 16 {
		if _, e = rand.Read(b[:]); e != nil {
			return nil, e
		}
		mark := tunEndian.Uint32(b[:]) & 0x7fffffff
		if mark < 65536 {
			continue
		}
		used := false
		for _, o := range all {
			if o.marked(mark) {
				used = true
				break
			}
		}
		if !used {
			return &tunJournal{Version: 1, Boot: tunBoot(), Namespace: l.namespace, Session: hex.EncodeToString(id[:]), Mark: mark}, nil
		}
	}
	return nil, errors.New("cannot allocate an unused TUN ownership marker")
}
func createOwnedTUN(in map[string]any, j *tunJournal) (*os.File, int, error) {
	fd, e := unix.Open("/dev/net/tun", unix.O_RDWR|unix.O_CLOEXEC, 0)
	if e != nil {
		return nil, 0, e
	}
	f := os.NewFile(uintptr(fd), "velum0")
	ok := false
	defer func() {
		if !ok {
			f.Close()
		}
	}()
	ifr, e := unix.NewIfreq("velum0")
	if e != nil {
		return nil, 0, e
	}
	ifr.SetUint16(unix.IFF_TUN | unix.IFF_NO_PI | unix.IFF_TUN_EXCL)
	if e = unix.IoctlIfreq(fd, unix.TUNSETIFF, ifr); e != nil {
		return nil, 0, e
	}
	if e = unix.SetNonblock(fd, true); e != nil {
		return nil, 0, e
	}
	link, e := netlink.LinkByName("velum0")
	if e != nil {
		return nil, 0, e
	}
	if e = netlink.LinkSetAlias(link, "velum:"+j.Session); e != nil {
		return nil, 0, e
	}
	mtu := 1400
	switch v := in["mtu"].(type) {
	case int:
		mtu = v
	case float64:
		mtu = int(v)
	}
	if e = netlink.LinkSetMTU(link, mtu); e != nil {
		return nil, 0, e
	}
	addresses, e := tunAddresses(in, "address")
	if e != nil {
		return nil, 0, e
	}
	for _, p := range addresses {
		addr, e := netlink.ParseAddr(p.String())
		if e != nil {
			return nil, 0, e
		}
		addr.Flags = unix.IFA_F_NODAD
		if e = netlink.AddrAdd(link, addr); e != nil {
			return nil, 0, e
		}
	}
	if e = netlink.LinkSetUp(link); e != nil {
		return nil, 0, e
	}
	ok = true
	return f, link.Attrs().Index, nil
}
func (l *tunLease) install(j *tunJournal, mutate func(tunObject, bool) error) error {
	if len(j.Objects) > tunMaxObjects {
		return errors.New("TUN plan too large")
	}
	j.Hash = tunPlanHash(j.Objects)
	if e := l.write(j); e != nil {
		return e
	}
	for i, o := range j.Objects {
		j.Attempt = i + 1
		if e := l.write(j); e != nil {
			return e
		}
		if e := mutate(o, true); e != nil {
			if errors.Is(e, unix.EEXIST) {
				j.Attempt = i
				if we := l.write(j); we != nil {
					return errors.Join(e, we)
				}
			}
			return e
		}
		// Prove serialization round-trips before publishing further objects.
		objects, e := tunDump(o.Kind, int(o.Wire[0]))
		if e != nil {
			return e
		}
		key, _ := o.canonical()
		count := 0
		for _, actual := range objects {
			other, e := actual.canonical()
			if e != nil {
				return e
			}
			if other == key {
				count++
			}
		}
		if count != 1 {
			return fmt.Errorf("TUN resource identity not confirmed (%s family %d, object %d): %d matches", o.Kind, o.Wire[0], i, count)
		}
	}
	return nil
}

// A numeric index is used only while the creating process holds the original
// nonpersistent TUN FD; no global resolver files or foreign link settings change.
func configureTUNDNS(index int, in map[string]any) error {
	if _, e := os.Stat("/run/systemd/resolve"); errors.Is(e, os.ErrNotExist) {
		return nil
	} else if e != nil {
		return e
	}
	addresses, e := tunAddresses(in, "address")
	if e != nil {
		return e
	}
	servers := []string{}
	for _, p := range addresses {
		servers = append(servers, p.Addr().Next().String())
	}
	return setTUNResolved(index, servers)
}
