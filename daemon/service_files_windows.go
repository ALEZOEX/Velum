//go:build windows

package main

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"unsafe"

	"golang.org/x/sys/windows"
)

func serviceDataDir() (string, error) {
	base, err := windows.KnownFolderPath(windows.FOLDERID_ProgramData, 0)
	if err != nil {
		return "", fmt.Errorf("locate system ProgramData: %w", err)
	}
	if err = localServicePath(base); err != nil {
		return "", err
	}
	return filepath.Join(base, "Velum"), nil
}

func localServicePath(path string) error {
	if len(path) < 3 || path[1] != ':' || path[2] != '\\' || !((path[0] >= 'A' && path[0] <= 'Z') || (path[0] >= 'a' && path[0] <= 'z')) || filepath.Clean(path) != path || strings.ContainsAny(path[2:], ":/\x00") {
		return fmt.Errorf("service path must be a canonical local drive path: %q", path)
	}
	return nil
}

func currentUserSID() (string, error) {
	user, err := windows.GetCurrentProcessToken().GetTokenUser()
	if err != nil {
		return "", fmt.Errorf("query installing token SID: %w", err)
	}
	return user.User.Sid.String(), nil
}

func serviceDescriptor(directory bool, reader string, token bool) (*windows.SECURITY_DESCRIPTOR, error) {
	text := "O:BAG:BAD:P"
	for _, ace := range serviceExpectedACEs(directory, reader, token) {
		flags := ""
		if directory {
			flags = "OICI"
		}
		text += fmt.Sprintf("(A;%s;0x%x;;;%s)", flags, ace.mask, ace.sid)
	}
	return windows.SecurityDescriptorFromString(text)
}

func descriptorSnapshot(sd *windows.SECURITY_DESCRIPTOR) (serviceObjectSecurity, error) {
	var s serviceObjectSecurity
	owner, _, err := sd.Owner()
	if err != nil || owner == nil {
		return s, fmt.Errorf("query security owner: %v", err)
	}
	s.owner = owner.String()
	control, _, err := sd.Control()
	if err != nil {
		return s, err
	}
	dacl, _, err := sd.DACL()
	if err != nil {
		return s, err
	}
	s.daclPresent = control&windows.SE_DACL_PRESENT != 0 && dacl != nil
	s.protected = control&windows.SE_DACL_PROTECTED != 0
	if dacl != nil {
		for i := uint32(0); i < uint32(dacl.AceCount); i++ {
			var raw *windows.ACCESS_ALLOWED_ACE
			if err = windows.GetAce(dacl, i, &raw); err != nil {
				return s, err
			}
			ace := serviceACE{kind: raw.Header.AceType, flags: raw.Header.AceFlags, mask: uint32(raw.Mask)}
			if ace.kind == windows.ACCESS_ALLOWED_ACE_TYPE || ace.kind == windows.ACCESS_DENIED_ACE_TYPE {
				if raw.Header.AceSize < 16 {
					return s, errors.New("invalid basic ACE size")
				}
				sid := (*windows.SID)(unsafe.Pointer(&raw.SidStart))
				if !sid.IsValid() || sid.Len()+8 > int(raw.Header.AceSize) {
					return s, errors.New("invalid ACE SID")
				}
				ace.sid = sid.String()
			}
			s.aces = append(s.aces, ace)
		}
	}
	runtime.KeepAlive(sd)
	return s, nil
}

func inspectServiceHandle(h windows.Handle) (serviceObjectSecurity, error) {
	var info windows.ByHandleFileInformation
	if err := windows.GetFileInformationByHandle(h, &info); err != nil {
		return serviceObjectSecurity{}, err
	}
	fileType, err := windows.GetFileType(h)
	if err != nil || fileType != windows.FILE_TYPE_DISK {
		return serviceObjectSecurity{}, errors.New("object is not a disk file/directory")
	}
	sd, err := windows.GetSecurityInfo(h, windows.SE_FILE_OBJECT, windows.OWNER_SECURITY_INFORMATION|windows.DACL_SECURITY_INFORMATION)
	if err != nil {
		return serviceObjectSecurity{}, err
	}
	s, err := descriptorSnapshot(sd)
	s.directory = info.FileAttributes&windows.FILE_ATTRIBUTE_DIRECTORY != 0
	s.reparse = info.FileAttributes&windows.FILE_ATTRIBUTE_REPARSE_POINT != 0
	s.links = info.NumberOfLinks
	return s, err
}

// Used only on newly created objects, never to "repair" an existing object.
// SetSecurityInfo replaces the entire DACL; GetSecurityInfo verifies reality.
func restrictACL(h windows.Handle, directory bool, reader string, token bool) error {
	sd, err := serviceDescriptor(directory, reader, token)
	if err != nil {
		return err
	}
	owner, _, err := sd.Owner()
	if err != nil {
		return err
	}
	dacl, _, err := sd.DACL()
	if err != nil {
		return err
	}
	err = windows.SetSecurityInfo(h, windows.SE_FILE_OBJECT, windows.OWNER_SECURITY_INFORMATION|windows.DACL_SECURITY_INFORMATION|windows.PROTECTED_DACL_SECURITY_INFORMATION, owner, nil, dacl, nil)
	runtime.KeepAlive(sd)
	if err != nil {
		return fmt.Errorf("set controlled DACL: %w", err)
	}
	s, err := inspectServiceHandle(h)
	if err != nil {
		return err
	}
	return validateServiceObject(s, directory, reader, token)
}

func serviceComponent(name string) bool {
	return name != "" && name != "." && name != ".." && !strings.ContainsAny(name, "\\/:\x00") && !strings.HasSuffix(name, ".") && !strings.HasSuffix(name, " ")
}

// Each lookup is one component relative to an already pinned directory.
// FILE_CREATE never opens/replaces an existing object. No truncation is used.
func serviceOpenAt(parent windows.Handle, name string, directory, create bool, sd *windows.SECURITY_DESCRIPTOR, extra uint32) (windows.Handle, error) {
	if !serviceComponent(name) {
		return 0, errors.New("invalid service path component")
	}
	objectName, err := windows.NewNTUnicodeString(name)
	if err != nil {
		return 0, err
	}
	oa := windows.OBJECT_ATTRIBUTES{Length: uint32(unsafe.Sizeof(windows.OBJECT_ATTRIBUTES{})), RootDirectory: parent, ObjectName: objectName, Attributes: windows.OBJ_CASE_INSENSITIVE | windows.OBJ_DONT_REPARSE, SecurityDescriptor: sd}
	options := uint32(windows.FILE_OPEN_REPARSE_POINT | windows.FILE_SYNCHRONOUS_IO_NONALERT)
	if directory {
		options |= windows.FILE_DIRECTORY_FILE
	} else {
		options |= windows.FILE_NON_DIRECTORY_FILE
	}
	access := uint32(windows.FILE_GENERIC_READ) | extra
	disposition := uint32(windows.FILE_OPEN)
	if create {
		disposition = windows.FILE_CREATE
		access |= windows.WRITE_DAC | windows.WRITE_OWNER
		if !directory {
			access |= windows.FILE_WRITE_DATA
		}
	}
	var handle windows.Handle
	var status windows.IO_STATUS_BLOCK
	err = windows.NtCreateFile(&handle, access, &oa, &status, nil, windows.FILE_ATTRIBUTE_NORMAL, windows.FILE_SHARE_READ, disposition, options, 0, 0)
	runtime.KeepAlive(sd)
	if err != nil {
		return 0, fmt.Errorf("open service component %q: %w", name, err)
	}
	return handle, nil
}

func serviceMissing(err error) bool {
	return errors.Is(err, windows.STATUS_OBJECT_NAME_NOT_FOUND) || errors.Is(err, windows.STATUS_OBJECT_PATH_NOT_FOUND)
}

type serviceTree struct {
	dir, reader string
	data, bin   windows.Handle
	handles     []windows.Handle
	files       map[string]windows.Handle
}

func (t *serviceTree) close() {
	for i := len(t.handles) - 1; i >= 0; i-- {
		_ = windows.CloseHandle(t.handles[i])
	}
	t.handles = nil
}
func (t *serviceTree) keep(h windows.Handle) windows.Handle {
	t.handles = append(t.handles, h)
	return h
}

func pinServicePath(path string, trusted bool) ([]windows.Handle, error) {
	if err := localServicePath(path); err != nil {
		return nil, err
	}
	root, err := windows.UTF16PtrFromString(`\\?\` + path[:3])
	if err != nil {
		return nil, err
	}
	h, err := windows.CreateFile(root, windows.FILE_GENERIC_READ, windows.FILE_SHARE_READ, nil, windows.OPEN_EXISTING, windows.FILE_FLAG_BACKUP_SEMANTICS|windows.FILE_FLAG_OPEN_REPARSE_POINT, 0)
	if err != nil {
		return nil, err
	}
	handles := []windows.Handle{h}
	success := false
	defer func() {
		if !success {
			for _, h := range handles {
				_ = windows.CloseHandle(h)
			}
		}
	}()
	var fs [32]uint16
	var flags uint32
	if err = windows.GetVolumeInformationByHandle(h, nil, 0, nil, nil, &flags, &fs[0], uint32(len(fs))); err != nil {
		return nil, err
	}
	if windows.UTF16ToString(fs[:]) != "NTFS" || flags&windows.FILE_PERSISTENT_ACLS == 0 {
		return nil, errors.New("service installation requires local NTFS with persistent ACLs")
	}
	parts := strings.Split(strings.TrimSuffix(path[3:], `\`), `\`)
	for i := 0; ; i++ {
		s, inspectErr := inspectServiceHandle(h)
		if inspectErr != nil {
			return nil, inspectErr
		}
		if trusted {
			if err = validateServiceAncestor(s, false); err != nil {
				// Standard ProgramData grants Users WRITE_ATTRIBUTES/WRITE_EA.
				// Those rights cannot add a reparse point to a nonempty NTFS
				// directory. Pin a real child entry, without share-delete, and
				// verify its file ID by enumerating the held parent handle.
				// No DELETE/DELETE_CHILD/ACL/owner grant is excused by this.
				if strictErr := validateServiceAncestor(s, true); strictErr != nil {
					return nil, fmt.Errorf("unsafe ancestor of %s: %w", path, strictErr)
				}
				childName := "Microsoft"
				if i < len(parts) && parts[i] != "" {
					childName = parts[i]
				}
				anchor, anchorErr := pinServiceAnchor(h, childName)
				if anchorErr != nil {
					return nil, fmt.Errorf("cannot safely anchor attribute-writable ancestor of %s: %w", path, anchorErr)
				}
				handles = append(handles, anchor)
				s, inspectErr = inspectServiceHandle(h)
				if inspectErr != nil {
					return nil, inspectErr
				}
				if err = validateServiceAncestor(s, true); err != nil {
					return nil, err
				}
			}
		} else if s.reparse || !s.directory {
			return nil, errors.New("source ancestor is a reparse point or not a directory")
		}
		if i >= len(parts) || parts[i] == "" {
			break
		}
		h, err = serviceOpenAt(h, parts[i], true, false, nil, 0)
		if err != nil {
			return nil, err
		}
		handles = append(handles, h)
	}
	// Callers use the last handle as the requested directory, not an anchor.
	for i, held := range handles {
		if held == h {
			handles = append(handles[:i], handles[i+1:]...)
			break
		}
	}
	handles = append(handles, h)
	success = true
	return handles, nil
}

// FILE_ID_BOTH_DIR_INFO layout, with a flexible UTF-16 name starting at 104.
type serviceDirectoryIDEntry struct {
	NextEntryOffset, FileIndex                              uint32
	CreationTime, LastAccessTime, LastWriteTime, ChangeTime int64
	EndOfFile, AllocationSize                               int64
	FileAttributes, FileNameLength, EaSize                  uint32
	ShortNameLength                                         uint8
	ShortName                                               [12]uint16
	FileID                                                  int64
	FileName                                                [1]uint16
}

func pinServiceAnchor(parent windows.Handle, name string) (windows.Handle, error) {
	h, err := serviceOpenAt(parent, name, true, false, nil, 0)
	if err != nil {
		return 0, err
	}
	success := false
	defer func() {
		if !success {
			_ = windows.CloseHandle(h)
		}
	}()
	var childInfo, parentInfo windows.ByHandleFileInformation
	if err = windows.GetFileInformationByHandle(h, &childInfo); err != nil {
		return 0, err
	}
	if childInfo.FileAttributes&windows.FILE_ATTRIBUTE_REPARSE_POINT != 0 {
		return 0, errors.New("anchor is a reparse point")
	}
	if err = windows.GetFileInformationByHandle(parent, &parentInfo); err != nil {
		return 0, err
	}
	if childInfo.VolumeSerialNumber != parentInfo.VolumeSerialNumber {
		return 0, errors.New("anchor is on another volume")
	}
	id := uint64(childInfo.FileIndexHigh)<<32 | uint64(childInfo.FileIndexLow)
	buffer := make([]byte, 65536)
	class := uint32(windows.FileIdBothDirectoryRestartInfo)
	offset := int(unsafe.Offsetof(serviceDirectoryIDEntry{}.FileName))
	for batch := 0; batch < 4096; batch++ {
		err = windows.GetFileInformationByHandleEx(parent, class, &buffer[0], uint32(len(buffer)))
		if err != nil {
			return 0, fmt.Errorf("enumerate parent for anchor identity: %w", err)
		}
		class = windows.FileIdBothDirectoryInfo
		for pos := 0; ; {
			if pos+offset > len(buffer) {
				return 0, errors.New("invalid directory entry header")
			}
			entry := (*serviceDirectoryIDEntry)(unsafe.Pointer(&buffer[pos]))
			size := int(entry.FileNameLength)
			if size%2 != 0 || size < 0 || size > len(buffer)-pos-offset {
				return 0, errors.New("invalid directory entry name")
			}
			value := windows.UTF16ToString(unsafe.Slice(&entry.FileName[0], size/2))
			if strings.EqualFold(value, name) {
				if uint64(entry.FileID) != id {
					return 0, errors.New("anchor identity does not match actual parent entry")
				}
				success = true
				return h, nil
			}
			if entry.NextEntryOffset == 0 {
				break
			}
			next := int(entry.NextEntryOffset)
			if next < offset || next > len(buffer)-pos {
				return 0, errors.New("invalid directory entry offset")
			}
			pos += next
		}
	}
	return 0, errors.New("anchor was not found in bounded directory enumeration")
}

func openServiceTree(create bool) (*serviceTree, error) {
	dir, err := serviceDataDir()
	if err != nil {
		return nil, err
	}
	reader, err := currentUserSID()
	if err != nil {
		return nil, err
	}
	return openServiceTreeAt(dir, reader, create)
}

// The path is supplied only by KnownFolder in production; tests can use a
// unique sibling in ProgramData inside an explicitly authorized disposable VM.
func openServiceTreeAt(dir, reader string, create bool) (*serviceTree, error) {
	ancestors, err := pinServicePath(filepath.Dir(dir), true)
	if err != nil {
		return nil, err
	}
	t := &serviceTree{dir: dir, reader: reader, handles: ancestors, files: make(map[string]windows.Handle)}
	success := false
	defer func() {
		if !success {
			t.close()
		}
	}()
	parent := ancestors[len(ancestors)-1]
	rootName := filepath.Base(dir)
	for _, name := range []string{rootName, "bin"} {
		h, e := serviceOpenAt(parent, name, true, false, nil, 0)
		if serviceMissing(e) && create {
			sd, e := serviceDescriptor(true, reader, false)
			if e != nil {
				return nil, e
			}
			h, e = serviceOpenAt(parent, name, true, true, sd, 0)
			if e != nil {
				return nil, e
			}
			t.keep(h)
			if e = restrictACL(h, true, reader, false); e != nil {
				return nil, e
			}
		} else {
			if e != nil {
				return nil, e
			}
			t.keep(h)
			s, e := inspectServiceHandle(h)
			if e != nil {
				return nil, e
			}
			if e = validateServiceObject(s, true, reader, false); e != nil {
				return nil, fmt.Errorf("unsafe existing %s: %w; no automatic repair performed", name, e)
			}
		}
		if name == rootName {
			t.data = h
		} else {
			t.bin = h
		}
		parent = h
	}
	if err = t.validateExisting(); err != nil {
		return nil, err
	}
	success = true
	return t, nil
}

// Do not descend into arbitrary children. Unknown objects are preserved and
// cause refusal, including nested directories, junctions and old staging files.
func (t *serviceTree) validateExisting() error {
	for _, directory := range []struct {
		path string
		h    windows.Handle
		data bool
	}{{t.dir, t.data, true}, {filepath.Join(t.dir, "bin"), t.bin, false}} {
		entries, err := os.ReadDir(directory.path)
		if err != nil {
			return err
		}
		for _, entry := range entries {
			name := entry.Name()
			if directory.data && name == "bin" {
				continue
			}
			allowed := directory.data && name == "token" || !directory.data && (name == "velumd.exe" || name == "sing-box.exe" || name == "xray.exe")
			if !allowed {
				return fmt.Errorf("unexpected existing service object %s; preserved for administrator inspection", filepath.Join(directory.path, name))
			}
			h, err := serviceOpenAt(directory.h, name, false, false, nil, 0)
			if err != nil {
				return err
			}
			t.keep(h)
			s, err := inspectServiceHandle(h)
			if err != nil {
				return err
			}
			if err = validateServiceObject(s, false, t.reader, name == "token"); err != nil {
				return fmt.Errorf("unsafe existing %s: %w; object was not modified", name, err)
			}
			t.files[name] = h
		}
	}
	return nil
}

func (t *serviceTree) verify() error {
	for _, h := range []windows.Handle{t.data, t.bin} {
		s, err := inspectServiceHandle(h)
		if err != nil {
			return err
		}
		if err = validateServiceObject(s, true, t.reader, false); err != nil {
			return err
		}
	}
	for name, h := range t.files {
		s, err := inspectServiceHandle(h)
		if err != nil {
			return err
		}
		if err = validateServiceObject(s, false, t.reader, name == "token"); err != nil {
			return fmt.Errorf("final verification of %s: %w", name, err)
		}
	}
	return nil
}

func sourceServiceFile(path string) (*os.File, func(), error) {
	ancestors, err := pinServicePath(filepath.Dir(path), false)
	if err != nil {
		return nil, nil, err
	}
	closeParents := func() {
		for _, h := range ancestors {
			_ = windows.CloseHandle(h)
		}
	}
	h, err := serviceOpenAt(ancestors[len(ancestors)-1], filepath.Base(path), false, false, nil, 0)
	if err != nil {
		closeParents()
		return nil, nil, err
	}
	var info windows.ByHandleFileInformation
	if err = windows.GetFileInformationByHandle(h, &info); err != nil || info.FileAttributes&(windows.FILE_ATTRIBUTE_DIRECTORY|windows.FILE_ATTRIBUTE_REPARSE_POINT) != 0 || info.NumberOfLinks != 1 {
		_ = windows.CloseHandle(h)
		closeParents()
		return nil, nil, fmt.Errorf("unsafe source executable %s: %v", path, err)
	}
	file := os.NewFile(uintptr(h), path)
	return file, func() { _ = file.Close(); closeParents() }, nil
}

func handleDigest(h windows.Handle) ([32]byte, error) {
	var duplicate windows.Handle
	if err := windows.DuplicateHandle(windows.CurrentProcess(), h, windows.CurrentProcess(), &duplicate, 0, false, windows.DUPLICATE_SAME_ACCESS); err != nil {
		return [32]byte{}, err
	}
	f := os.NewFile(uintptr(duplicate), "service-file")
	defer f.Close()
	if _, err := f.Seek(0, io.SeekStart); err != nil {
		return [32]byte{}, err
	}
	hash := sha256.New()
	if _, err := io.Copy(hash, f); err != nil {
		return [32]byte{}, err
	}
	var result [32]byte
	copy(result[:], hash.Sum(nil))
	return result, nil
}

type serviceRenameInfo struct {
	ReplaceIfExists uint8
	RootDirectory   windows.Handle
	FileNameLength  uint32
	FileName        [1]uint16
}

func renameServiceFile(h, parent windows.Handle, name string) error {
	if !serviceComponent(name) {
		return errors.New("invalid publication name")
	}
	utf, err := windows.UTF16FromString(name)
	if err != nil {
		return err
	}
	utf = utf[:len(utf)-1]
	offset := unsafe.Offsetof(serviceRenameInfo{}.FileName)
	buffer := make([]byte, int(offset)+2*len(utf))
	info := (*serviceRenameInfo)(unsafe.Pointer(&buffer[0]))
	info.RootDirectory = parent
	info.FileNameLength = uint32(2 * len(utf))
	copy(unsafe.Slice(&info.FileName[0], len(utf)), utf)
	var status windows.IO_STATUS_BLOCK
	return windows.NtSetInformationFile(h, &status, &buffer[0], uint32(len(buffer)), windows.FileRenameInformation)
}

func deleteServiceHandle(h windows.Handle) error {
	deleteFile := byte(1)
	return windows.SetFileInformationByHandle(h, windows.FileDispositionInfo, &deleteFile, 1)
}

func (t *serviceTree) publish(parent windows.Handle, name string, token bool, write func(*os.File) error) error {
	var random [16]byte
	if _, err := rand.Read(random[:]); err != nil {
		return err
	}
	stage := ".stage-" + hex.EncodeToString(random[:])
	sd, err := serviceDescriptor(false, t.reader, token)
	if err != nil {
		return err
	}
	h, err := serviceOpenAt(parent, stage, false, true, sd, windows.DELETE)
	if err != nil {
		return err
	}
	f := os.NewFile(uintptr(h), stage)
	published := false
	defer func() {
		if !published {
			_ = deleteServiceHandle(h)
		}
		_ = f.Close()
	}()
	if err = restrictACL(h, false, t.reader, token); err != nil {
		return err
	}
	if err = write(f); err != nil {
		return err
	}
	if err = f.Sync(); err != nil {
		return err
	}
	if err = renameServiceFile(h, parent, name); err != nil {
		return fmt.Errorf("publish %s without replacement: %w", name, err)
	}
	published = true
	if err = f.Close(); err != nil {
		return err
	}
	// Reopen read-only before SCM use; no writable image handle stays open.
	read, err := serviceOpenAt(parent, name, false, false, nil, 0)
	if err != nil {
		return err
	}
	t.keep(read)
	s, err := inspectServiceHandle(read)
	if err != nil {
		return err
	}
	if err = validateServiceObject(s, false, t.reader, token); err != nil {
		return err
	}
	t.files[name] = read
	return nil
}

func (t *serviceTree) copyExecutable(source, name string) error {
	input, closeInput, err := sourceServiceFile(source)
	if err != nil {
		return err
	}
	defer closeInput()
	if existing, ok := t.files[name]; ok {
		want, err := handleDigest(windows.Handle(input.Fd()))
		if err != nil {
			return err
		}
		actual, err := handleDigest(existing)
		if err != nil {
			return err
		}
		if want != actual {
			return fmt.Errorf("trusted existing %s differs from source; uninstall the old service before replacing binaries", name)
		}
		return nil
	}
	return t.publish(t.bin, name, false, func(output *os.File) error { _, err := io.Copy(output, input); return err })
}

func (t *serviceTree) ensureToken() error {
	if h, ok := t.files["token"]; ok {
		var duplicate windows.Handle
		if err := windows.DuplicateHandle(windows.CurrentProcess(), h, windows.CurrentProcess(), &duplicate, 0, false, windows.DUPLICATE_SAME_ACCESS); err != nil {
			return err
		}
		f := os.NewFile(uintptr(duplicate), "token")
		defer f.Close()
		data, err := io.ReadAll(io.LimitReader(f, 257))
		if err != nil {
			return err
		}
		value := strings.TrimSpace(string(data))
		if len(data) > 256 || len(value) < 32 {
			return errors.New("existing token has invalid length")
		}
		return nil
	}
	var raw [32]byte
	if _, err := rand.Read(raw[:]); err != nil {
		return err
	}
	return t.publish(t.data, "token", true, func(f *os.File) error { _, err := f.WriteString(hex.EncodeToString(raw[:]) + "\n"); return err })
}

func (t *serviceTree) release(h windows.Handle) {
	for i, held := range t.handles {
		if held == h {
			_ = windows.CloseHandle(h)
			t.handles[i] = 0
			return
		}
	}
}

func (t *serviceTree) removeBinaries() error {
	for _, name := range []string{"velumd.exe", "sing-box.exe", "xray.exe"} {
		old, exists := t.files[name]
		if !exists {
			continue
		}
		t.release(old)
		h, err := serviceOpenAt(t.bin, name, false, false, nil, windows.DELETE)
		if err != nil {
			return err
		}
		s, err := inspectServiceHandle(h)
		if err == nil {
			err = validateServiceObject(s, false, t.reader, false)
		}
		if err == nil {
			err = deleteServiceHandle(h)
		}
		_ = windows.CloseHandle(h)
		if err != nil {
			return fmt.Errorf("remove verified %s: %w", name, err)
		}
		delete(t.files, name)
	}
	t.release(t.bin)
	h, err := serviceOpenAt(t.data, "bin", true, false, nil, windows.DELETE)
	if err != nil {
		return err
	}
	defer windows.CloseHandle(h)
	s, err := inspectServiceHandle(h)
	if err != nil {
		return err
	}
	if err = validateServiceObject(s, true, t.reader, false); err != nil {
		return err
	}
	// The kernel refuses a nonempty directory. No recursive traversal exists.
	return deleteServiceHandle(h)
}
