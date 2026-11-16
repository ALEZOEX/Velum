# Linux TUN ownership and recovery (F2)

## Verified cause

Pinned sing-box **1.12.12** imports sing-tun **v0.7.3**. Its Linux
`Start()` configures the interface, installs routes, calls `unsetRules()`,
and installs rules. Both rollback and `Close()` use `unsetRules()` too.
That function deletes by family and priority in `[rule_index, rule_index+10]`,
without proving ownership. Separate indices alone do not fix it. A real
namespace regression reproduced deletion of a foreign IPv4 rule added during
an active session. SIGKILL also bypasses userspace cleanup; closing the last
nonpersistent TUN FD removes its link/device routes, but not policy rules.

Sources inspected directly in the pinned Go module cache:

- [sing-tun Linux lifecycle](https://github.com/SagerNet/sing-tun/blob/v0.7.3/tun_linux.go)
- [sing-tun route construction](https://github.com/SagerNet/sing-tun/blob/v0.7.3/tun_rules.go)
- [sing-box inbound](https://github.com/SagerNet/sing-box/blob/v1.12.12/protocol/tun/inbound.go)

## Alternatives

| Approach | Benefits | Cost / limitation |
| --- | --- | --- |
| Patch sing-tun's add/delete tracking | Reuses native route logic | Must modify startup, partial rollback, rule and route deletion, and persist an external journal for SIGKILL anyway. Every upstream update needs a cleanup audit. |
| Velum controller, exclusive TUN FD, durable journal and independent supervisor | One authority records exact resources; no native range cleanup; works in console and service modes | Owns a deliberately limited Linux policy implementation; kernel attribute normalization and FD integration need tests on updates. |
| systemd coordination alone | Existing cgroups and restart hooks | Cannot make stock sing-tun stop deleting foreign priorities. Does not cover console mode or prove resource ownership. |

Selected: the controller plus systemd recovery hooks. There is **no sing-tun
fork**. A two-line sing-box adapter exposes the existing `FileDescriptor`
option (see `patches/`). Stock JSON has no FD field. `auto_route=false` is
insufficient: native sing-tun still installs/removes an IPv6 output-interface
rule by priority. FD mode bypasses native link setup, routing, cleanup and
resolved commands altogether. An unpatched core rejects the config before
TUN creation; there is no unsafe fallback. `make core` builds the pinned
adapter on Linux. Windows continues to use stock sing-box and its existing
TUN configuration/lifecycle.

## Ownership model

- Convention: interface `velum0`, table **27841**, priorities **27841–27851**.
  These are not globally reserved. Preflight checks both families, table
  references, goto targets, link/address collisions and unsupported options.
- A per-network-namespace **flock** lease in `/run/velum-tun/net-<dev>-<ino>`
  serializes all Velum setup/recovery. State directories must be private,
  root-owned, without extended ACLs or symlink components. Lock/journal must
  be regular single-link private files. Openat/NOFOLLOW protects lookup.
- The supervisor creates a nonpersistent TUN with `IFF_TUN_EXCL`. It retains
  the original FD, labels the link with a random session ID, and passes FD3
  to the core. It never deletes a link by a stale name/index. The core also
  inherits the lease on FD4, keeping recovery excluded if it outlives the
  supervisor. Closing the original FDs lets the kernel remove that link.
- Each rule carries `FRA_PROTOCOL=251`, a random per-session nonzero
  `FRA_FWMARK`, and **FWMASK=0**. This is identity metadata: it matches every
  packet and does not set/change packet marks. Routes use protocol251 and
  metric=the same random value. It is not sufficient to match these tags alone.
- The root-private journal contains boot ID, namespace identity, random
  session ID, marker, complete raw netlink objects, plan hash and attempted
  installation boundary. Each intent is atomically written/fsynced **before**
  Add. Successful adds are verified against a kernel dump before continuing.
  Unknown ACK results remain recoverable. A definite EEXIST retracts that
  intent; the pre-existing object is never adopted.
- The pinned netlink.Rule decoder drops action/protocol/unknown attributes.
  Ownership therefore uses complete rtnetlink payloads, not Rule.String or
  priority/table comparisons. Canonical comparison preserves selectors,
  actions, creator flags and unknown attributes. Only kernel default encodings,
  alignment, volatile resolution flags and non-expiring cache counters are
  normalized. Non-default port masks, expiry and errors remain significant.
- Cleanup first validates journal/context and **all** session-tagged objects.
  Missing objects are allowed (kernel cleanup or earlier completed rollback).
  Modified/duplicate identities cause a safe refusal with the journal retained.
  Each delete is preceded by another dump and carries the full observed object,
  including marker and selectors. A final dump confirms removal before the
  journal is unlinked. No range deletion, table flush or global DNS reset exists.

Current-session resources are protected by the live lease/FD. Previous-session
resources require a matching boot/namespace journal and exact attributes.
Unmarked old rules, foreign tags, corrupt journals, live unknown `velum0` and
untrusted state files are never automatically adopted/deleted. No journal means
no network cleanup; preflight still rejects occupied resources. Errors remain
visible in daemon state/API; disconnect cannot claim successful restoration.

## Process and systemd recovery

The supervisor is a separate velumd process. Parent EOF detects SIGKILL of the
main daemon independently of its defers. It stops/waits for the core, closes
its own FD, then replays exact journal cleanup. Core Pdeathsig is a secondary
signal request, with its spawning OS thread pinned for its lifetime. The
supervisor deliberately has no Pdeathsig. Pipe-draining waits are bounded even
if a stopped orphan core holds inherited log pipes.

| Event | Recovery |
| --- | --- |
| Disconnect / SIGTERM | Supervisor stops the core, closes the TUN and cleans exact journal objects. Repeated disconnect is a no-op. |
| SIGKILL main daemon | EOF wakes the surviving supervisor, which performs the same cleanup. |
| SIGKILL core | Supervisor observes exit and cleans; the daemon reports an error and can reconnect. |
| Supervisor and core both killed / full cgroup killed | Persistent `/run` journal survives. A separate `velumd --recover-tun`, next `--tun` startup, or next TUN preflight recovers under the lease. |
| Core survives, including SIGSTOP | Its inherited lease blocks recovery. No guessed cleanup; stop the known owned process before retrying. |
| Partial setup / lost ACK | Journal lists only attempted objects; missing objects are tolerated. Already created exact matches are rolled back. |
| Damaged/changed ownership state | Fail closed, retain journal and actionable error; operator diagnosis required. |

The generated unit adds `ExecStartPre` / `ExecStopPost` recovery and preserves
private `RuntimeDirectory=velum velum-tun` across stop/restart, including forced
termination. The service's read-only filesystem sandbox permits those runtime
directories. **Actual systemd installation/cgroup kill was not executed in this
task.** Existing installations require updating their unit through the installer;
binary replacement alone does not add hooks. Console mode has independent
supervision plus next-start recovery, but no perpetual external watchdog if
both processes are killed. A machine reboot removes this tmpfs state and the
kernel's previous routing state together.

## Routing and DNS scope

The controller implements only the audited configuration generated by Velum:
IPv4/IPv6, strict-route, default routes with server endpoint exclusions, native
policy selectors, and IPv6 unreachable when disabled. No UID filters,
auto_redirect, arbitrary route_address or extra policy schemes are supported.
The physical outbound interface is fixed before installing routes, preventing
TUN from becoming its own uplink. XHTTP companion remains separate and unchanged.

Only this live TUN's systemd-resolved per-link domain/default-route/DNS settings
are configured, using its numeric ifindex while the creating FD is held. A
failed command aborts startup. Link removal removes its per-link DNS state;
global resolver files and other VPN links are never reset. Real resolved desktop
integration is **UNVERIFIED**; test mounts hide `/run` and disable the host bus.

## Verification and remaining limits

Real user/network/mount/PID namespace tests exercise kernel netlink operations and
the pinned FD core, not mock ownership. The test wrapper refuses root/host
network fallback, verifies distinct namespaces and an initially empty network,
and mounts a private tmpfs `/run`. Each case gets a fresh namespace; PID-namespace teardown also kills stopped
fixture children if a test aborts.

Covered: repeated dual-stack connect/disconnect, competing Velum starts,
pre-existing and mid-session foreign rules/routes, partial rule failure,
lost ACK, definite EEXIST, modified identities, exclusive duplicate rejection,
corrupt journal, unmarked residual refusal, core SIGKILL, daemon SIGTERM/SIGKILL,
separate recovery after simultaneous supervisor/core death, live-core lease,
and reconnection. Snapshots include complete IPv4/IPv6 rules and all route tables;
foreign VPN sentinels at priorities9000/table2022 survive.

Data-plane tests confirm IPv4/IPv6 TCP and UDP/TCP DNS interception via a local
SOCKS fixture. A separate two-namespace test confirms actual Hysteria2, Reality +
Vision and XHTTP bridge traffic, A/AAAA over proxy DoH, disconnect and SIGTERM.
**That complete network suite fails its direct-CIDR egress assertion** (direct
TCP timeout/reset). The same failure was reproduced on clean origin/main
`0c2e2cdf0e6853dd2c33da5f235167c16c157278` with stock core. It is an existing
routing limitation, not silently marked PASS or fixed outside this F2 change.
The test continues through later protocols but still returns failure.

Limits:

1. A competing CAP_NET_ADMIN/root process can inspect/copy markers or replace
   an object with an identical one between dump and delete (ABA). Linux offers
   no authenticated ownership token/transaction for these objects. Exact
   matching plus random markers prevents ordinary priority collisions, **not
   arbitrary privileged interference**. A dedicated network namespace with
   deliberate host traffic plumbing is the stronger boundary, outside this fix.
2. Kernel link teardown necessarily removes *any* route another privileged
   process attaches to our ephemeral link. Foreign routes on other interfaces
   are preserved. Cooperation is required to avoid intentionally sharing velum0.
3. Changed/unknown attributes or journal corruption intentionally leave some
   own rules behind. There is no unsafe heuristic recovery. Recovery errors,
   missing hooks, or a surviving stopped core can require operator action.
4. Namespace proofs do not validate every kernel, policy precedence with Happ,
   physical-network DNS leaks, Windows runtime, or a real systemd restart.
   Server address changes still require reconnect/resolution; automatic
   reconciliation of DNS endpoint changes is outside this patch.

Recorded development checks (Linux 7.3.1-1-cachyos, Go1.27.3 linux/amd64):

| Check | Result |
| --- | --- |
| `go test ./...` with explicit freshly built pinned core | PASS |
| `go test -race ./...` | PASS |
| `go vet ./...`; Windows amd64 vet | PASS |
| Linux/Windows amd64 daemon builds; Windows test cross-compilation | PASS; Windows runtime not run |
| Ownership wrapper with `VELUM_F2_RACE=1` | PASS: all 17 isolated cases |
| Pinned sing-box config checks (including Vision, Hysteria2, XHTTP bridge config) | PASS |
| Complete two-namespace protocol suite | FAIL: pre-existing direct-CIDR egress; Hysteria2/Vision/XHTTP/DNS/shutdown passed |
| Shell/Python syntax and Git whitespace checks | PASS |
| Real installed systemd lifecycle / host TUN / desktop resolved | UNVERIFIED |

Flutter and Windows TUN implementation were not changed. No Flutter checks or
Windows runtime were performed for this change. F15 installer path/rollback work
is not included; the installer diff here only adds TUN recovery unit directives.

Safe checks on a physical Linux workstation (keep Happ running):

```sh
make core daemon
cd daemon
go test ./...
go test -race ./...
go vet ./...
cd ..
VELUM_F2_RACE=1 scripts/test-linux-tun-ownership.sh
python3 scripts/test-linux-network.py   # see known failing direct-CIDR case
```

Requires Python3, patch, Go, iproute2, unshare/mount, `/dev/net/tun` and enabled
unprivileged user namespaces; the network suite also needs OpenSSL and pinned
Xray. If isolation is denied, the wrapper fails; never retry with host TUN or
privilege escalation. Optional `VELUM_TEST_CORE`/`VELUM_TEST_DAEMON` paths select
fresh binaries without replacing existing ignored development artifacts.
Use `velumd --recover-tun` **only in the isolated namespace during tests**.
Do not run/install the service or TUN in the workstation's primary namespace.
