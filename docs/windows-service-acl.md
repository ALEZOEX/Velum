# F1: Windows service installation boundary

Status: implemented candidate, **not confirmed closed** until native NTFS and
SCM behavior is validated on a suitable disposable Windows VM. Linux mocks,
Windows cross-compilation, Wine and in-memory descriptor tests are insufficient
for that conclusion. No Windows service installation was performed during the
Linux development session.

## Threat model and root cause

A local non-administrator may pre-create destination directories/files, retain
explicit write ACEs, own an object whose DACL currently looks restrictive, or
redirect path traversal using junctions/symlinks/reparse points/hard links. The
installer is elevated; SCM normally runs velumd as LocalSystem. The protected
asset is the complete executable/token path, not just the file's write bit.

Previously `icacls /inheritance:r /grant:r` retained unrelated explicit ACEs,
did not establish a trusted owner and was not followed by descriptor readback.
MkdirAll/Stat followed paths, the destination was opened with O_TRUNC, the
ProgramData environment variable selected the privileged destination, and
uninstall used recursive path-based deletion.

Administrators, SYSTEM, TrustedInstaller and kernel compromise are outside the
non-administrator boundary. Source-package authenticity and the already elevated
installer's own provenance are assumptions, not established by destination ACLs.
The UAC prompt must authorize a trusted package. This patch does not implement
signatures or change GUI token delegation to a different elevated identity.
These are points of interaction with the remaining privilege-boundary audit;
F12/F13 themselves are not evaluated or marked fixed here.

## Implemented controls

1. SHGetKnownFolderPath(FOLDERID_ProgramData), not an environment-derived
   destination. Only canonical local drive paths on NTFS with persistent ACLs
   are accepted. Remote paths, alternate streams and ambiguous components fail.
2. Pin ancestors one component at a time. The volume root is opened with
   OPEN_REPARSE_POINT/BACKUP_SEMANTICS; subsequent NtCreateFile operations are
   relative to held directory handles with FILE_OPEN_REPARSE_POINT and
   OBJ_DONT_REPARSE. Sharing permits readers only, denying write/delete handle
   sharing. Every opened component is inspected for actual type and reparse flag.
3. Ancestors must be owned by SYSTEM, Administrators or TrustedInstaller. Their
   current-object ACEs must not grant nontrusted subjects DELETE_CHILD, DELETE,
   WRITE_DAC, WRITE_OWNER, write attributes/EA, generic write or generic all.
   ProgramData may legitimately permit creating children; FILE_CREATE handles
   the race for Velum's name by failing if another object wins creation.
4. Existing service objects must already have a trusted SYSTEM/Administrators
   owner and the exact protected allow-only DACL. Explicit deny, inherited,
   unexpected and duplicate ACEs are refused. Files must have exactly one hard
   link. Unknown children/nested directories are refused, not traversed or deleted.
   The entire existing root/bin/token/binaries are checked before any file copy.
5. New objects are created with an explicit owner and protected descriptor.
   restrictACL now takes a **handle**, replaces the complete DACL using
   SetSecurityInfo, then reads GetSecurityInfo and file metadata back and validates
   them. It is never called to repair an unsafe pre-existing object.
6. Controlled DACL: SYSTEM/Administrators full access; elevated installer's SID
   read/execute on directories and binaries, read on token. No generic additional
   user/group grants. A different installing identity may cause conservative
   refusal; access is not silently broadened to accommodate it.
7. Token is confined to the canonical tree. Existing tokens are opened without
   following reparses and checked before reading. No ACL rewrite of a foreign
   token, no external --token-file destination, no truncation.
8. Sources are held read-only, disallowing concurrent write/delete sharing, and
   checked for regular single-link/non-reparse type. New destination files use
   random CREATE_NEW staging names inside the secured tree, write/flush, and
   handle-relative rename **without replacement**. Existing verified files are
   reused only when SHA-256 equals the held source. Differing files are refused.
   No existing executable is opened with write/truncate access.
9. Each binary publication is atomic on the accepted filesystem; the set of all
   binaries is not one filesystem transaction. Until all files and token pass
   readback, SCM registration/start cannot occur. Already published files after a
   later failure remain protected and can be reused on a safe retry. A failed
   stage is marked for deletion by its own handle. A crash may leave a stage;
   an unknown stage then causes refusal pending explicit diagnosis.
10. After SCM registration descriptors are verified again before Start. Failure
    triggers disable/stop/delete attempts and returns combined errors. No failed
    cleanup is silently reported successful. No pre-existing service is overwritten
    or started by install. Already-installed service returns an error unchanged.
11. Uninstall validates/pins the entire tree before SCM changes. It waits for a
    confirmed stopped service and validates again, then deletes only named verified
    binary handles. The kernel must accept deletion of an **empty** bin directory.
    Token/root are retained. There is no RemoveAll/recursive link traversal.

Legacy trees with individual-user ownership or leftover ACEs are deliberately
not migrated automatically, even if created by an earlier Velum installer.
Uninstall also refuses such a tree. An administrator must diagnose and migrate
or quarantine it in a separate approved operation; do not recursively "fix"
permissions or delete an unverified link target. Conservative refusal is a
compatibility cost of closing this boundary.

## Remaining limits

- Native filesystem/SCM semantics still require actual Windows validation,
  including share-mode compatibility with the image loader and security software.
- Multi-file publication is not atomic. No service is registered on copy/ACL
  failures; complete protected binaries/token can remain. Interrupted cleanup
  may require inspection of an unknown stage.
- Path pinning and exact DACLs protect against current non-administrators, not
  concurrent privileged administrators, pre-existing capabilities acquired while
  a tree was insecure, kernel filesystem filters, or malicious source packages.
  A descriptor snapshot cannot prove an object's entire security history.
- Filesystem final checks are not a perpetual monitor. ACL changes made by an
  administrator after installation remain outside the stated boundary.
- The installer's binary and selected source package must already be trusted;
  UAC elevation of arbitrary user-writable code cannot be repaired by destination
  ACLs. NTFS is required; no claim is made for SMB, FAT or ReFS.
- The GUI's existing installer entry point is retained. Token access for a
  different account used for UAC elevation or custom SCM account is not expanded.
- Uninstall with unsafe state refuses rather than attempting service repair.
  An already unsafe running installation needs an explicit incident-response or
  migration procedure; invoking this installer does not make it trustworthy.

## Verification layers

`service_install_policy_test.go` runs on Linux and Windows. It tests exact owner,
DACL, type, link and ancestor decisions and production install/remove ordering
with injected failures. Its stateful matrix checks SCM registration/start gates,
preservation of pre-existing/foreign content, and safe retries after second/third
binary or ACL-operation failures. It does not emulate Windows enforcement using
Unix permissions.

`service_files_windows_test.go` contains Windows-only tests for native SDDL
parsing/readback, unsafe descriptors, Known Folder vs environment, component
validation and amd64 FILE_RENAME_INFORMATION layout. Standard Windows CI runs
these without service installation. A separate opt-in test exercises real NTFS
creation, owner/DACL readback, reuse, failed-write cleanup, no-replace publication
and rejection of a writable executable. It never registers/starts a service.

## Disposable Windows 11 VM procedure

Do not run these experiments on the user's physical Windows installation.
Use a fresh Windows 11 VM snapshot, no existing Velum service/tree, no secrets,
no shared host directories at test destinations, and a local NTFS system drive.
Disconnect external networking if packages/tools have already been copied in.

Build on Linux without running Windows binaries:

```sh
cd daemon
GOOS=windows GOARCH=amd64 CGO_ENABLED=0 go test -c -o /tmp/velum-f1.test.exe .
GOOS=windows GOARCH=amd64 CGO_ENABLED=0 go build -o /tmp/velumd.exe .
```

Copy the test binary and this repository's test script into the VM. In an
elevated VM PowerShell session, explicitly authorize **fixture-only** tests:

```powershell
.\scripts\test-windows-service-acl.ps1 -TestBinary C:\F1\velum-f1.test.exe -DisposableVM
```

The script refuses an unrecognized VM model, a non-elevated shell or an existing
Velum service. It only enables the opt-in filesystem test; it never installs a
service or starts VPN/TUN. Fixture paths are fresh `ProgramData\Velum-F1-<random>`
siblings, not the production `Velum` path. Tests intentionally retain fixtures
for inspection. Preserve output and descriptors, then revert the snapshot.

### Separate SCM end-to-end matrix (requires explicit VM installation approval)

This part is **not run by the script or standard CI**. Before any service
installation, obtain permission for this exact disposable VM. Use a trusted
staged package with velumd/sing-box/optional Xray; record its hashes. Never send
connect requests. Invoke `velumd.exe --service install` **without --tun** for
these installation-only checks. No network engine connection is necessary.

Create a disposable standard local account, e.g. `VelumF1User`, inside the VM
only. Record its SID as `$userSid`. Create a separate outside sentinel file and
record content/hash/security descriptor. For each matrix row, restore the clean
VM snapshot first. Construct fixtures with Get-Acl/Set-Acl and explicit
FileSystemAccessRule objects; use SID-based trustees to avoid localized names.

| Case | Fixture/action | Required result |
| --- | --- | --- |
| 1 Clean | No Velum destination; install trusted package | SCM uses verified canonical path; LocalSystem default; owner BA/SY and exact protected DACL everywhere. |
| 2 Safe repeat | Repeat install with SCM present; also retry a safe partial tree with SCM absent | Present SCM yields unchanged refusal; absent SCM and matching files can complete without replacing them. |
| 3 User owner | Pre-create Velum with owner `$userSid`, even if its DACL is restrictive | Refuse; no SCM creation/start, no automatic take-ownership. |
| 4 Extra ACE | BA-owned protected directory plus explicit user Write/Modify or deny ACE | Refuse unchanged; unrelated ACE is not silently removed. |
| 5 Writable exe | Otherwise safe tree with user-write ACE on velumd.exe | Refuse before executing/registering it. |
| 6 Junction/reparse | Replace Velum or bin with a junction to the outside sentinel directory (`New-Item -ItemType Junction`) | Refuse; outside content and descriptor unchanged. |
| 7 File links | Destination exe symlink to outside file; separately `New-Item -ItemType HardLink` | Refuse both; never truncate target. Also test alternate data stream names are rejected. |
| 8 Token | Unsafe owner, user-write ACE, directory, symlink and hard link, separately | Refuse without modifying token/target. External --token-file is refused. |
| 9 Partial writes | Run fixture fault tests; separately remove/deny a later trusted source before install | No registration/start; previous published files protected; restore source and retry safely. |
| 10 ACL failure | Run injected-policy tests and opt-in native descriptor checks; use VM debugger/API fault injection for actual SetSecurityInfo/GetSecurityInfo failure | No registration/start; error returned; no false security confirmation. Native API fault injection has not been implemented by this script. |
| 11 No admin | Invoke installer from a standard/non-elevated token | Refuse before any filesystem/SCM change. |
| 12 Unsafe uninstall | After a safe VM install, add unsafe ACL or replace a path with a junction as VM admin, then uninstall | Refuse before SCM stop/delete or filesystem deletion; outside sentinel unchanged. Restore snapshot, not recursive cleanup. |

For **each** row record: Get-Service/sc.exe query and qc output; whether Start
was attempted (event log or a trusted inert SCM test executable); destination and
outside hashes; owner, AreAccessRulesProtected and full SDDL for every object;
whether any remaining unsafe object was merely preserved or newly created; and
the outcome of a retry after explicit fixture correction. Probe file write,
rename/delete and Set-Acl under the **standard account**, not only under the
administrator running the installer. They must fail for installed objects.
Preserve command output without token contents and revert the VM afterwards.

Native API references:

- [NtCreateFile relative RootDirectory/disposition/options](https://learn.microsoft.com/en-us/windows/win32/api/winternl/nf-winternl-ntcreatefile)
- [CreateFile sharing/reparse semantics](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-createfilew)
- [SetSecurityInfo replaces the supplied DACL](https://learn.microsoft.com/en-us/windows/win32/api/aclapi/nf-aclapi-setsecurityinfo)
- [GetSecurityInfo actual descriptor readback](https://learn.microsoft.com/en-us/windows/win32/api/aclapi/nf-aclapi-getsecurityinfo)
- [GetFileInformationByHandle identity/link metadata](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-getfileinformationbyhandle)
