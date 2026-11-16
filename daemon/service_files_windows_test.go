//go:build windows

package main

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"unsafe"

	"golang.org/x/sys/windows"
)

func TestServiceNativeDescriptorReadback(t *testing.T) {
	reader := "S-1-5-21-1-2-3-1001"
	for _, directory := range []bool{false, true} {
		for _, token := range []bool{false, true} {
			sd, err := serviceDescriptor(directory, reader, token)
			if err != nil {
				t.Fatal(err)
			}
			s, err := descriptorSnapshot(sd)
			if err != nil {
				t.Fatal(err)
			}
			s.directory, s.links = directory, 1
			if err = validateServiceObject(s, directory, reader, token); err != nil {
				t.Fatal(err)
			}
		}
	}
	for _, text := range []string{
		"O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;FA;;;WD)",
		"O:SYG:SYD:P(D;;FA;;;WD)(A;;FA;;;SY)(A;;FA;;;BA)",
		"O:BAG:BAD:NO_ACCESS_CONTROL",
	} {
		sd, err := windows.SecurityDescriptorFromString(text)
		if err != nil {
			t.Fatal(err)
		}
		s, err := descriptorSnapshot(sd)
		if err != nil {
			t.Fatal(err)
		}
		s.links = 1
		if err = validateServiceObject(s, false, "", false); err == nil {
			t.Fatalf("unsafe native descriptor accepted: %s", text)
		}
	}
}

func TestServiceKnownFolderIgnoresEnvironment(t *testing.T) {
	before, err := serviceDataDir()
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("ProgramData", `C:\attacker-controlled`)
	after, err := serviceDataDir()
	if err != nil {
		t.Fatal(err)
	}
	if before != after {
		t.Fatal("privileged install trusts ProgramData environment")
	}
}

func TestServiceNativeRenameLayout(t *testing.T) {
	if unsafe.Sizeof(uintptr(0)) != 8 {
		t.Skip("amd64 layout")
	}
	if unsafe.Offsetof(serviceRenameInfo{}.RootDirectory) != 8 || unsafe.Offsetof(serviceRenameInfo{}.FileNameLength) != 16 || unsafe.Offsetof(serviceRenameInfo{}.FileName) != 20 {
		t.Fatal("incorrect FILE_RENAME_INFORMATION layout")
	}
	if unsafe.Offsetof(serviceDirectoryIDEntry{}.FileID) != 96 || unsafe.Offsetof(serviceDirectoryIDEntry{}.FileName) != 104 {
		t.Fatal("incorrect FILE_ID_BOTH_DIR_INFO layout")
	}
}

func TestServiceNativePathPolicy(t *testing.T) {
	for _, path := range []string{`\\server\share\Velum`, `\\?\C:\ProgramData`, `C:\ProgramData\..\Temp`, `C:\ProgramData:stream`, `C:relative`} {
		if localServicePath(path) == nil {
			t.Fatalf("unsafe path accepted: %s", path)
		}
	}
	for _, name := range []string{"..", `a\b`, `a/b`, `token:stream`, `bin.`, `bin `} {
		if _, err := serviceOpenAt(0, name, false, false, nil, 0); err == nil {
			t.Fatalf("unsafe component accepted: %s", name)
		}
	}
}

// Real NTFS/ACL operations, never enabled in ordinary CI/go test. No SCM,
// network engine, route or service installation is performed even when opted in.
// Run only via the documented disposable Windows 11 VM procedure.
func TestServiceFilesystemDisposableVM(t *testing.T) {
	if os.Getenv("VELUM_F1_DISPOSABLE_VM") != "1" {
		t.Skip("explicit disposable Windows VM authorization required")
	}
	if err := requireElevation(); err != nil {
		t.Fatal(err)
	}
	base, err := serviceDataDir()
	if err != nil {
		t.Fatal(err)
	}
	reader, err := currentUserSID()
	if err != nil {
		t.Fatal(err)
	}
	// A fresh unique name is mandatory. Never operate on the real Velum tree.
	var suffix [16]byte
	if _, err = rand.Read(suffix[:]); err != nil {
		t.Fatal(err)
	}
	dir := filepath.Join(filepath.Dir(base), "Velum-F1-"+hex.EncodeToString(suffix[:]))
	if _, err = os.Lstat(dir); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("fixture path is not absent")
	}
	tree, err := openServiceTreeAt(dir, reader, true)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(tree.close)
	t.Log("Fixture is intentionally retained for inspection; revert the VM snapshot:", dir)
	if err = tree.ensureToken(); err != nil {
		t.Fatal(err)
	}
	if err = tree.publish(tree.bin, "velumd.exe", false, func(f *os.File) error { _, err := f.WriteString("inert fixture, never executed"); return err }); err != nil {
		t.Fatal(err)
	}
	if err = tree.verify(); err != nil {
		t.Fatal(err)
	}
	tree.close()
	// Existing secure objects are accepted unchanged.
	tree, err = openServiceTreeAt(dir, reader, false)
	if err != nil {
		t.Fatal(err)
	}
	defer tree.close()
	if err = tree.ensureToken(); err != nil {
		t.Fatal(err)
	}
	// Write failure must not leave a published destination or unsafe stage.
	err = tree.publish(tree.bin, "sing-box.exe", false, func(f *os.File) error { _, _ = f.WriteString("partial"); return errors.New("injected write error") })
	if err == nil {
		t.Fatal("write failure ignored")
	}
	if _, err = os.Lstat(filepath.Join(dir, "bin", "sing-box.exe")); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("partial binary was published")
	}
	if err = tree.publish(tree.bin, "sing-box.exe", false, func(f *os.File) error { _, err := f.WriteString("retry"); return err }); err != nil {
		t.Fatal(err)
	}
	if err = tree.verify(); err != nil {
		t.Fatal(err)
	}
	// Existing safe files must not be replaced, even by publish itself.
	if err = tree.publish(tree.bin, "velumd.exe", false, func(f *os.File) error { _, err := f.WriteString("replacement"); return err }); err == nil {
		t.Fatal("existing executable was replaced")
	}
	// Full controlled DACL is applied only to a new object. Existing unsafe
	// fixtures below are never passed to restrictACL for automatic repair.
	tree.close()
	path := filepath.Join(dir, "bin", "velumd.exe")
	ptr, _ := windows.UTF16PtrFromString(path)
	h, err := windows.CreateFile(ptr, windows.READ_CONTROL|windows.WRITE_DAC, windows.FILE_SHARE_READ, nil, windows.OPEN_EXISTING, windows.FILE_FLAG_OPEN_REPARSE_POINT, 0)
	if err != nil {
		t.Fatal(err)
	}
	bad, err := windows.SecurityDescriptorFromString("D:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;FA;;;WD)")
	if err != nil {
		t.Fatal(err)
	}
	dacl, _, err := bad.DACL()
	if err != nil {
		t.Fatal(err)
	}
	err = windows.SetSecurityInfo(h, windows.SE_FILE_OBJECT, windows.DACL_SECURITY_INFORMATION|windows.PROTECTED_DACL_SECURITY_INFORMATION, nil, nil, dacl, nil)
	_ = windows.CloseHandle(h)
	if err != nil {
		t.Fatal(err)
	}
	if unsafeTree, err := openServiceTreeAt(dir, reader, false); err == nil {
		unsafeTree.close()
		t.Fatal("writable executable accepted")
	}
}
