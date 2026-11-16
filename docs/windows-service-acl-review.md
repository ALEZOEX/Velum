# F1 security review for PR #1

Review date: 2026-11-16. Reviewed implementation:
`b13ea1481ecd147059b2f3904e983ae939c8f36c`.
Base main: `2a502c8d6733e768247101008e240ee7e02692d9`.

Decision: no blocking F1 defect identified by this source review; eligible for
alpha integration after CI passes on the actual PR head. **F1 is not fully
closed.** No production code change was needed during this review. The review
read the implementation and test harnesses rather than inferring correctness
from earlier PASS reports. It was performed by the assistant, not a separate
human security team or an independent Windows 11 lab.

## Scope and assumptions

The adversary is a local non-administrator attempting to substitute service
executables, redirect privileged file operations, read the Bearer token, or
induce execution of an incomplete/untrusted installation as LocalSystem.
The destination is the system Known Folder ProgramData on local NTFS.
The installer and its selected source package must already be trusted.
Concurrent administrators, SYSTEM, TrustedInstaller, kernel/filesystem-filter
compromise and capabilities retained from a previously insecure installation
are not defeated by this destination-ACL policy.

Reviewed files: `daemon/windows_service.go`, `daemon/service_files_windows.go`,
`daemon/service_install_policy.go`, their tests, both Windows ACL/SCM harnesses,
and `scripts/install-windows-service.ps1`. Related reads included daemon path,
token and API initialization, GUI service installation/token lookup, x/sys
SCM invocation and the CI workflow. F12/F13 are not evaluated as complete fixes.

## Security conclusions from source

- **Owner and DACL.** `validateServiceObject` in `service_install_policy.go`
  accepts only SYSTEM/Administrators ownership, a non-null protected DACL and
  the complete expected ACE set including masks and flags. Extra, deny,
  inherited, duplicate or write-enabled reader ACEs fail. Accepted service
  DACLs are allow-only, so ordering cannot hide a deny/allow precedence issue.
  `restrictACL` replaces the descriptor on newly created objects only and
  reads it back through `GetSecurityInfo`; existing unsafe objects are refused.
- **Paths and identity.** `serviceDataDir` uses KnownFolder rather than the
  environment. `pinServicePath` and `serviceOpenAt` open each component relative
  to a held directory, reject reparse points and deny delete sharing. Files
  also deny write sharing. A link count other than one rejects a file, including
  token and source executables. Parent DELETE_CHILD/ACL/ownership grants to
  untrusted subjects are rejected. Attribute-writable system ancestors require
  a held child with matching file ID, keeping the ancestor nonempty. This
  relies on documented NTFS reparse behavior, not on a chmod analogy.
- **Publication.** `publish` creates a random staging object with FILE_CREATE
  and a controlled descriptor, writes and flushes it, then renames relative to
  the pinned parent with replacement disabled. It reopens read-only and verifies
  the actual descriptor before accepting the file. The close/reopen interval
  relies on the protected parent/file ACLs; it is not an atomic guarantee
  against concurrent administrators. An existing safe binary is never truncated
  and is reused only when its hash matches the held source.
- **SCM gates.** `runServiceInstall` requires elevation, preparation, all
  copies and verification before registration. `installService` refuses an
  existing service without changing/restarting it; constructs fixed service,
  core and token paths; then verifies again before Start. A startup failure
  attempts disable/stop/delete and reports combined errors. The service command
  line is built by x/sys SCM APIs, not shell concatenation. The service object
  uses the SCM default descriptor; this patch does not grant another user
  SERVICE_CHANGE_CONFIG, WRITE_DAC or WRITE_OWNER. Native impersonated attempts
  to acquire those SCM rights are not part of the current harness.
- **Removal.** `uninstallService` pins and validates the tree before stopping
  or deleting the service, waits for Stopped and verifies again. Binary deletion
  is by reopened, revalidated handles; the empty-directory kernel check replaces
  recursive removal. A partial deletion failure can leave protected remnants
  requiring administrator inspection; it cannot justify deleting unknown files.
- **Token.** `ensureToken` validates an existing opened object, bounds its
  content length and never rewrites it. New tokens use 32 random bytes and the
  same no-replace publication. Only SYSTEM, Administrators and the elevated
  installing SID receive access; that SID gets read, not write. No token content
  is emitted by the test harness. A different administrator used for UAC is a
  different reader: the original GUI user may be unable to authenticate. The
  code does not broaden ACLs to compensate. This remains a Windows 11/F12
  delegation and usability question, not evidence of outsider token access.

API contracts were checked against Microsoft documentation for
[NtCreateFile](https://learn.microsoft.com/en-us/windows/win32/api/winternl/nf-winternl-ntcreatefile),
[SetSecurityInfo](https://learn.microsoft.com/en-us/windows/win32/api/aclapi/nf-aclapi-setsecurityinfo),
[nonempty-directory reparse refusal](https://learn.microsoft.com/en-us/windows-hardware/drivers/ifs/fsctl-set-reparse-point)
and [SCM/service access rights](https://learn.microsoft.com/en-us/windows/win32/services/service-security-and-access-rights).

## Adversarial scenarios and evidence

| Preconditions / attempt | Expected control and code evidence | Actual evidence | Remaining uncertainty |
| --- | --- | --- | --- |
| User precreates a writable destination or token, then requests elevated install | Exact owner/DACL/type validation in `openServiceTreeAt` / `validateExisting`; refuse without repairing the object or registering SCM | Native SCM harness refuses extra user-write ACEs on root, executable and token; preserves descriptors/content; portable tests reject a user owner | User-owned tree/token through the complete native installer remains UNVERIFIED |
| User redirects bin to a junction or adds file links | Relative no-reparse opens, type and link-count checks; no destination overwrite | Native SCM junction refusal leaves outside sentinel content/SDDL unchanged; native path checks and portable link policy tests pass | Full native SCM executable symlink/hardlink and token-type variants remain UNVERIFIED |
| User races publication or a later binary copy fails | Held directories/files, FILE_CREATE staging, no-replace rename; all copies and descriptor checks before SCM | Native NTFS write-failure cleanup, safe retry and no-replace checks pass; production orchestration fault tests prevent registration on second/third-copy failures | No exhaustive adversarial race test; full SCM copy/API fault injection remains UNVERIFIED |
| Foreign standard user tries to modify the installed tree or read the token | Complete protected DACLs and trusted owners; no foreign SID grants | Real LogonUser/impersonation probes with positive controls; service stopped and installer handles closed; only ERROR_ACCESS_DENIED accepted; hashes/SDDL unchanged | Does not prove absence of previously retained handles/mappings, or impersonated denial of SCM configuration rights |
| Reinstall or unsafe uninstall would touch existing objects | Refuse existing service before filesystem work; validate tree before SCM removal; delete verified named objects only | Real SCM repeat install keeps PID; unsafe executable ACL blocks uninstall unchanged; stop/restart/uninstall and final cleanup pass | Injected SCM rollback failures and unexpected external service changes remain UNVERIFIED |
| GUI uses UAC credentials for another administrator | Token remains limited to installing SID; no automatic delegation | Supported by token/GUI source review only | Windows 11 GUI/UAC, alternate identity and custom service accounts remain UNVERIFIED; F12 remains open |

The native harness uses the actual daemon installed through SCM as LocalSystem,
with inert version-only sing-box/Xray fixtures. It sends only GET /v1/status,
checks authenticated idle state and HTTP 401 without Bearer, and never connects
VPN or creates TUN. It verifies cleanup of its service, canonical tree, account
and sandbox; separate opt-in NTFS fixtures intentionally remain for VM disposal.
The portable policy tests verify decision/order properties. Their synthetic
snapshots do not demonstrate NTFS enforcement or actual SCM fault behavior.

## Verification of the reviewed implementation

[PR CI run 43901424309](https://github.com/ALEZOEX/Velum/actions/runs/43901424309)
completed successfully for the reviewed SHA: daemon; Windows service security;
Flutter Windows; Ubuntu, Debian, Arch and openSUSE. The Windows security log
identifies Microsoft Windows Server 2025, image `windows-2025-vs2026`
`20261103.298.1`. All 13 SCM harness checks passed:
[job](https://github.com/ALEZOEX/Velum/actions/runs/43901424309/job/133418767368),
[results artifact](https://github.com/ALEZOEX/Velum/actions/runs/43901424309/artifacts/14241094052).

Local repeated checks on Linux passed:

- `go test -count=1 ./...` and `go test -race -count=1 ./...` (daemon).
- `go vet ./...`; Windows amd64 `go vet ./...`.
- Static Linux amd64 and Windows amd64 daemon builds; Windows unit-test
  compilation. Cross-compilation does not execute Windows ACLs.
- `flutter analyze --no-pub`; `flutter test --no-pub --reporter expanded`:
  138 passed, 2 platform skips.
- `git diff --check`.

The final documentation commit must have green CI before merging; the GitHub
merge operation must be pinned to its expected head. Do not infer that a newer
head passed from the older run above. No real VPN, TUN, host routing/DNS change
or local privileged operation was used in this review.

## Remaining status

No new CRITICAL/HIGH F1 implementation defect was established. Original F1 is
mitigated with native evidence for the documented subset, not fully closed.
The full negative matrix in [the design](windows-service-acl.md) remains open:
native user ownership/link/type cases, non-elevated invocation, native ACL API
failures, later-copy and rollback failures through the complete SCM installer.
No Windows 11 VM was available for additional interactive GUI/UAC checks.
Those checks and real Windows VPN/TUN runtime are **UNVERIFIED**.

The ACL policy is not source-package authentication or perpetual monitoring.
Protected partial files/stages may require explicit inspection after failures;
legacy insecure trees are deliberately not repaired automatically. The existing
F2 race/crash-routing limitations, F9 tray availability, and F10-F15 findings
are not reclassified by this review.
