package main

import (
	"errors"
	"fmt"
)

const (
	serviceSystemSID                  = "S-1-5-18"
	serviceAdminsSID                  = "S-1-5-32-544"
	serviceTrustedInstallerSID        = "S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464"
	serviceFullAccess          uint32 = 0x1f01ff
	serviceRead                uint32 = 0x120089
	serviceReadExecute         uint32 = 0x1200a9
)

// An OS-independent projection of a Windows descriptor, not a Unix ACL model.
type serviceACE struct {
	sid         string
	mask        uint32
	kind, flags uint8
}
type serviceObjectSecurity struct {
	owner                                      string
	daclPresent, protected, directory, reparse bool
	links                                      uint32
	aces                                       []serviceACE
}

func serviceExpectedACEs(directory bool, reader string, token bool) []serviceACE {
	flags := uint8(0)
	if directory {
		flags = 3
	} // OBJECT/CONTAINER_INHERIT_ACE
	result := []serviceACE{{sid: serviceSystemSID, mask: serviceFullAccess, flags: flags}, {sid: serviceAdminsSID, mask: serviceFullAccess, flags: flags}}
	if reader != "" && reader != serviceSystemSID && reader != serviceAdminsSID {
		mask := serviceReadExecute
		if token {
			mask = serviceRead
		}
		result = append(result, serviceACE{sid: reader, mask: mask, flags: flags})
	}
	return result
}

func validateServiceObject(s serviceObjectSecurity, directory bool, reader string, token bool) error {
	if s.reparse || s.directory != directory || (!directory && s.links != 1) {
		return errors.New("reparse point, hard link or incorrect object type")
	}
	if s.owner != serviceSystemSID && s.owner != serviceAdminsSID {
		return fmt.Errorf("untrusted owner %s", s.owner)
	}
	if !s.daclPresent || !s.protected {
		return errors.New("DACL must be present, non-null and protected from inheritance")
	}
	want := serviceExpectedACEs(directory, reader, token)
	if len(s.aces) != len(want) {
		return errors.New("unexpected explicit ACEs; refusing automatic ACL repair")
	}
	seen := make(map[serviceACE]bool)
	for _, ace := range s.aces {
		if seen[ace] {
			return errors.New("duplicate ACE")
		}
		seen[ace] = true
	}
	for _, ace := range want {
		if !seen[ace] {
			return errors.New("DACL differs from the controlled allow-only policy")
		}
	}
	return nil
}

func validateServiceAncestor(s serviceObjectSecurity) error {
	if s.reparse || !s.directory || !s.daclPresent {
		return errors.New("ancestor is a reparse point, non-directory or has a null DACL")
	}
	if s.owner != serviceSystemSID && s.owner != serviceAdminsSID && s.owner != serviceTrustedInstallerSID {
		return fmt.Errorf("untrusted ancestor owner %s", s.owner)
	}
	// Ancestors such as ProgramData may allow creation of subdirectories.
	// DELETE_CHILD, ownership/ACL or attribute changes may redirect our tree.
	const unsafe uint32 = 0x10000000 | 0x40000000 | 0x80000 | 0x40000 | 0x10000 | 0x100 | 0x10 | 0x40
	for _, ace := range s.aces {
		if ace.flags&8 != 0 || ace.kind == 1 {
			continue
		} // inherit-only or deny
		if ace.kind != 0 {
			return errors.New("unsupported ancestor ACE type")
		}
		if ace.sid == serviceSystemSID || ace.sid == serviceAdminsSID || ace.sid == serviceTrustedInstallerSID {
			continue
		}
		if ace.mask&unsafe != 0 {
			return fmt.Errorf("ancestor permits replacement/ACL changes by %s", ace.sid)
		}
	}
	return nil
}

// A small orchestration seam shared by production and fault-injection tests.
// Filesystem operations still have to enforce the native handle policy.
type serviceInstallPlan struct {
	elevate, prepare, verify, register, start, rollback func() error
	files                                               []func() error
}

func runServiceInstall(p serviceInstallPlan) error {
	for _, step := range []func() error{p.elevate, p.prepare} {
		if err := step(); err != nil {
			return err
		}
	}
	for _, step := range p.files {
		if err := step(); err != nil {
			return err
		}
	}
	if err := p.verify(); err != nil {
		return err
	}
	if err := p.register(); err != nil {
		return err
	}
	if err := p.start(); err != nil {
		return errors.Join(err, p.rollback())
	}
	return nil
}

func runServiceRemoval(elevate, inspect, remove func() error) error {
	if err := elevate(); err != nil {
		return err
	}
	if err := inspect(); err != nil {
		return err
	}
	return remove()
}
