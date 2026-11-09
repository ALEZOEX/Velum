package main

import (
	"errors"
	"reflect"
	"testing"
)

func TestServiceObjectPolicyRejectsUnsafeObjects(t *testing.T) {
	reader := "S-1-5-21-1-2-3-1001"
	for _, tc := range []struct {
		name   string
		change func(*serviceObjectSecurity)
	}{
		{"user_owner", func(s *serviceObjectSecurity) { s.owner = reader }},
		{"extra_write_ace", func(s *serviceObjectSecurity) { s.aces = append(s.aces, serviceACE{sid: "S-1-1-0", mask: 2}) }},
		{"deny_ace", func(s *serviceObjectSecurity) { s.aces[0].kind = 1 }},
		{"null_dacl", func(s *serviceObjectSecurity) { s.daclPresent = false }},
		{"unprotected", func(s *serviceObjectSecurity) { s.protected = false }},
		{"inherited_ace", func(s *serviceObjectSecurity) { s.aces[0].flags |= 0x10 }},
		{"reparse", func(s *serviceObjectSecurity) { s.reparse = true }},
		{"hardlink", func(s *serviceObjectSecurity) { s.links = 2 }},
		{"wrong_type", func(s *serviceObjectSecurity) { s.directory = true }},
		{"reader_write", func(s *serviceObjectSecurity) { s.aces[2].mask |= 2 }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s := safeServiceSnapshot(false, reader, false)
			tc.change(&s)
			if err := validateServiceObject(s, false, reader, false); err == nil {
				t.Fatal("unsafe existing object accepted")
			}
		})
	}
}

func TestServiceObjectPolicyExactDACL(t *testing.T) {
	for _, directory := range []bool{false, true} {
		for _, token := range []bool{false, true} {
			s := safeServiceSnapshot(directory, "S-1-5-21-1-2-3-1001", token)
			if err := validateServiceObject(s, directory, "S-1-5-21-1-2-3-1001", token); err != nil {
				t.Fatal(err)
			}
		}
	}
}

func TestServiceInstallGateOrdering(t *testing.T) {
	// Models OS failures only. These tests do not claim to emulate Windows ACLs.
	for _, failure := range []string{"", "elevation", "tree", "binary1", "binary2", "binary3", "acl_readback", "register", "start"} {
		t.Run(failure, func(t *testing.T) {
			var calls []string
			registered, started := false, false
			step := func(name string) func() error {
				return func() error {
					calls = append(calls, name)
					if failure == name {
						return errors.New(name)
					}
					return nil
				}
			}
			err := runServiceInstall(serviceInstallPlan{
				elevate: step("elevation"), prepare: step("tree"), files: []func() error{step("binary1"), step("binary2"), step("binary3")}, verify: step("acl_readback"),
				register: func() error {
					if err := step("register")(); err != nil {
						return err
					}
					registered = true
					return nil
				},
				start: func() error {
					if err := step("start")(); err != nil {
						return err
					}
					started = true
					return nil
				},
				rollback: func() error { calls = append(calls, "rollback"); registered = false; return nil },
			})
			if failure == "" {
				if err != nil || !registered || !started {
					t.Fatalf("clean/safe repeat failed: %v", err)
				}
				want := []string{"elevation", "tree", "binary1", "binary2", "binary3", "acl_readback", "register", "start"}
				if !reflect.DeepEqual(calls, want) {
					t.Fatal(calls)
				}
			} else if err == nil || registered || started {
				t.Fatalf("unsafe installation state: %v registered=%v started=%v", err, registered, started)
			}
		})
	}
}

func TestServiceAncestorPolicy(t *testing.T) {
	s := safeServiceSnapshot(true, "", false)
	s.protected = false // System ancestors may legitimately inherit.
	s.aces = append(s.aces, serviceACE{sid: "S-1-5-32-545", mask: 0x1200a9 | 4})
	if err := validateServiceAncestor(s); err != nil {
		t.Fatal(err)
	}
	s.aces[len(s.aces)-1].mask |= 0x40 // FILE_DELETE_CHILD overrides child ACL.
	if err := validateServiceAncestor(s); err == nil {
		t.Fatal("ancestor permits child replacement")
	}
}

func TestServiceInstallNegativeMatrix(t *testing.T) {
	const reader = "S-1-5-21-1-2-3-1001"
	for _, scenario := range []string{"clean", "safe_repeat", "directory_owner", "extra_write_ACE", "writable_exe", "junction", "exe_symlink", "exe_hardlink", "token_owner", "token_ACL", "token_type", "second_binary", "third_binary", "ACL_error", "ACL_readback_mismatch", "not_admin"} {
		t.Run(scenario, func(t *testing.T) {
			objects := map[string]serviceObjectSecurity{}
			content := map[string]string{"unrelated": "unchanged"}
			if scenario != "clean" {
				objects["root"] = safeServiceSnapshot(true, reader, false)
				objects["bin"] = safeServiceSnapshot(true, reader, false)
			}
			if scenario == "safe_repeat" {
				for _, name := range []string{"velumd.exe", "sing-box.exe", "xray.exe", "token"} {
					objects[name] = safeServiceSnapshot(false, reader, name == "token")
					content[name] = "valid"
				}
			}
			mutate := func(name string, change func(*serviceObjectSecurity)) {
				s := safeServiceSnapshot(name == "root" || name == "bin", reader, name == "token")
				change(&s)
				objects[name] = s
				content[name] = "preexisting"
			}
			switch scenario {
			case "directory_owner":
				mutate("root", func(s *serviceObjectSecurity) { s.owner = reader })
			case "extra_write_ACE":
				mutate("bin", func(s *serviceObjectSecurity) { s.aces = append(s.aces, serviceACE{sid: "S-1-1-0", mask: 2}) })
			case "writable_exe":
				mutate("velumd.exe", func(s *serviceObjectSecurity) { s.aces[2].mask |= 2 })
			case "junction":
				mutate("bin", func(s *serviceObjectSecurity) { s.reparse = true })
			case "exe_symlink":
				mutate("velumd.exe", func(s *serviceObjectSecurity) { s.reparse = true })
			case "exe_hardlink":
				mutate("velumd.exe", func(s *serviceObjectSecurity) { s.links = 2 })
			case "token_owner":
				mutate("token", func(s *serviceObjectSecurity) { s.owner = reader })
			case "token_ACL":
				mutate("token", func(s *serviceObjectSecurity) { s.protected = false })
			case "token_type":
				mutate("token", func(s *serviceObjectSecurity) { s.directory = true })
			}
			before := make(map[string]string)
			for k, v := range content {
				before[k] = v
			}
			registered, started := false, false
			fault := scenario
			validate := func() error {
				for name, s := range objects {
					if err := validateServiceObject(s, name == "root" || name == "bin", reader, name == "token"); err != nil {
						return err
					}
				}
				return nil
			}
			p := serviceInstallPlan{
				elevate: func() error {
					if scenario == "not_admin" {
						return errors.New("elevation required")
					}
					return nil
				},
				prepare: func() error {
					if err := validate(); err != nil {
						return err
					}
					for _, name := range []string{"root", "bin"} {
						objects[name] = safeServiceSnapshot(true, reader, false)
					}
					return nil
				},
				verify: func() error {
					if scenario == "ACL_readback_mismatch" {
						s := objects["token"]
						s.protected = false
						objects["token"] = s
					}
					return validate()
				},
				register: func() error { registered = true; return nil }, start: func() error { started = true; return nil }, rollback: func() error { registered = false; return nil },
			}
			for index, name := range []string{"velumd.exe", "sing-box.exe", "xray.exe", "token"} {
				p.files = append(p.files, func() error {
					if fault == "second_binary" && index == 1 || fault == "third_binary" && index == 2 || fault == "ACL_error" {
						return errors.New("injected write/ACL failure before publication")
					}
					if _, exists := objects[name]; !exists {
						objects[name] = safeServiceSnapshot(false, reader, name == "token")
						content[name] = "valid"
					}
					return nil
				})
			}
			err := runServiceInstall(p)
			success := scenario == "clean" || scenario == "safe_repeat"
			if success {
				if err != nil || !registered || !started {
					t.Fatalf("safe install/repeat failed: %v", err)
				}
			} else if err == nil || registered || started {
				t.Fatalf("unsafe case registered or started service: %v", err)
			}
			for name, value := range before {
				if content[name] != value {
					t.Fatalf("preexisting/foreign file %s changed", name)
				}
			}
			// Partial writes leave only previously verified published files;
			// existing malicious state is preserved for explicit remediation.
			if scenario == "second_binary" || scenario == "third_binary" || scenario == "ACL_error" {
				if err := validate(); err != nil {
					t.Fatal("partial failure left unsafe permissions")
				}
				fault = ""
				if err := runServiceInstall(p); err != nil {
					t.Fatal("safe retry was blocked", err)
				}
			}
		})
	}
}

func TestServiceUnsafeUninstallDoesNotDeleteOrStop(t *testing.T) {
	s := safeServiceSnapshot(true, "", false)
	s.reparse = true
	installed, running, foreign := true, true, "untouched"
	err := runServiceRemoval(func() error { return nil }, func() error { return validateServiceObject(s, true, "", false) }, func() error { installed = false; running = false; foreign = "deleted"; return nil })
	if err == nil || !installed || !running || foreign != "untouched" {
		t.Fatal("unsafe uninstall mutated service or foreign files")
	}
}

func safeServiceSnapshot(directory bool, reader string, token bool) serviceObjectSecurity {
	return serviceObjectSecurity{owner: serviceAdminsSID, daclPresent: true, protected: true, directory: directory, links: 1, aces: serviceExpectedACEs(directory, reader, token)}
}
