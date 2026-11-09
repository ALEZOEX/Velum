# Linux TUN: F2 mitigation and its limits

## Root cause verified against pinned source

Velum runs sing-box **1.12.12**, which imports sing-tun **v0.7.3**.
Previously the generated config omitted `iproute2_table_index` and
`iproute2_rule_index`; sing-box supplied **2022** and **9000**.

Relevant upstream sources:

- [sing-box TUN construction](https://github.com/SagerNet/sing-box/blob/v1.12.12/protocol/tun/inbound.go)
- [sing-tun Linux lifecycle](https://github.com/SagerNet/sing-tun/blob/v0.7.3/tun_linux.go)

`NativeTun.Start()` calls `setRoute()`, **then `unsetRules()`**, then
`setRules()`. `unsetRules()` enumerates both families and deletes by family
and priority within the inclusive interval `[rule_index, rule_index+10]`.
It does not check table, interface or creator. `Close()` and failed rule
installation also call this cleanup. IPv6-disabled `strict_route` can still
install an IPv6 unreachable rule. Route removal specifies table, destination,
gateway and interface index; it is narrower than policy-rule removal, but
its errors are ignored upstream. `Close()` errors are not actionable through
the existing daemon process API.

## Chosen bounded change

Linux configs now use **table 27841**, **priorities 27841–27851**, and
`velum0`. These numbers are an application convention based on Velum's
existing API port, **not globally reserved IDs**. They are distinct from
the problematic sing-box defaults, the observed Tailscale priorities
5210/5230/5250/5270 and table 52, and Linux built-ins 0/32766/32767 and
253/254/255. The policy interval is below main/default, so it can be reached
before those lookups. This does not establish routing precedence suitable
for every combination of VPNs.

The development machine was inspected read-only before selection: both
families had no rules in the new interval or references to table 27841;
both routing table dumps had no entries in that table, and `velum0` did not
exist. Happ and Tailscale were left running. This observation is not used
as a permanent assumption: **every start checks the actual namespace**.

Read-only netlink preflight checks:

- Every occupied priority in the entire cleanup interval, including unused
  slots, in IPv4 **and** IPv6, even with IPv6 disabled.
- Rules referring to the selected table, `goto` targets in the interval,
  and references to `velum0` outside the interval.
- Routes in the selected table in both families; all tables are enumerated
  with `RT_FILTER_TABLE`/`RT_TABLE_UNSPEC` (a plain RouteList omits non-main
  tables in this netlink implementation).
- Existing `velum0`, overlapping interface addresses and connected/local
  routes for the configured TUN prefixes. Default and split-default VPN
  routes are not treated as address collisions.
- The config uses the audited routing options. Auto-redirect, UID and
  interface policy filters are not generated and are refused by this guard;
  they would require extending the audited resource set.

Any read error or conflict cancels the start with a resource-specific error.
The guard has no mutating API. It never adopts or deletes stale-looking
resources. On replacement of an active owned TUN, the old core is stopped
first; the guard then checks what remains. When replacing proxy mode it
also checks before stopping the old connection. A final check is made before
launching either the core or companion. Windows configuration/cleanup and
XHTTP companion implementation are unchanged. The pre-stop check is skipped
only while an existing TUN core is still tracked; a historical `tunActive`
flag alone is never accepted as ownership of residual resources.

## Three important failure scenarios

| Scenario | Protection and remaining limit |
| --- | --- |
| Another VPN already occupies table, priority, interface or address resources | Start is refused without deletion. Read errors also fail closed. |
| Failed start or abnormal death leaves resources | Graceful cleanup remains in sing-tun. Restart refuses remaining resources instead of priority-range flushing. Hard-killed cores may leave rules requiring diagnosis. |
| Another application claims the interval after preflight | **Not prevented.** Stock sing-tun may delete its rules on startup, rollback or disconnect. Read-only preflight is not an atomic reservation. |

## Lifecycle outcomes

| Event | Expected behavior and evidence |
| --- | --- |
| Normal disconnect / replacement | Wait for child exit; upstream closes routes/rules/interface. Verified with real core and both IP modes in isolated namespaces. |
| Repeated disconnect | No second upstream Close after the child has been cleared. Verified, including a new foreign rule added after the first stop. |
| Partial startup | Verified failure of a later mixed inbound after `velum0` initialization: interface and routing snapshot return to baseline. Failure injected halfway through `setRules()` is **not** covered by this experiment; upstream uses the same unsafe range cleanup there. |
| SIGTERM velumd | Existing shutdown waits for the core. Verified in namespace; no residual routing in that run. |
| SIGKILL velumd | Existing Linux Pdeathsig requests SIGTERM in the child. Both clean termination and residual policy rules were observed in isolated runs. The regression test requires foreign routing to survive and restart to refuse any residual rules. Pdeathsig is not proof of graceful cleanup. |
| SIGKILL sing-box / hard crash | Kernel removes the nonpersistent TUN and its device routes when the last descriptor closes; policy rules can survive. Verified residual rules and rejection of restart, without deleting them. |
| Repeated daemon/service start | Same preflight each time, no boot-time flush. Daemon restart with residual rules is covered; real systemd unit restart was not performed. Existing KillMode=control-group and timeout escalation can hard-kill both processes and leave rules. |

No independent route-recovery process or flush-by-priority mechanism was added.
After an actual hard kill, do not assume matching priorities prove ownership.
Inspect both families and correlate with the previous run before any manual
repair. Prefer namespace teardown in tests. Production may require operator
intervention; automatic reconnection intentionally refuses an ambiguous state.

## Alternatives and residual scope

Changing only constants still permits deletion of pre-existing custom rules.
Choosing a different free range automatically can hide remnants and change
policy ordering; it does not solve atomic ownership. Both were rejected.

This patch protects against **known existing conflicts**, not arbitrary
concurrent changes for the lifetime of TUN. Strict ownership requires changing
the library: remove startup range flushing, record only successful additions,
roll back that set, and delete exact rule identities, with equivalent tracking
for partial route creation. Even exact matching cannot distinguish an identical
rule recreated by another privileged application after ours is removed. A
cooperating lock alone does not protect against other VPNs. A genuinely separate
network namespace provides a stronger kernel boundary but requires deliberate
traffic plumbing and is outside this targeted fix. No claim of complete F2
elimination is made for unmodified sing-tun v0.7.3.

## Safe verification on a physical Linux machine

Keep Happ running. Do not install/start the Velum system service and do not run
the daemon with `--tun` directly in your desktop's network namespace.

Run unit tests first:

```sh
cd /home/alezoex/velum/daemon
go test ./...
go vet ./...
go test -race ./...
```

For real kernel behavior, as an ordinary user with user namespaces enabled:

```sh
cd /home/alezoex/velum
bash scripts/test-linux-tun-ownership.sh
```

Requires the pinned `bin/sing-box`, Go, `ip` and `unshare`. The wrapper builds test
executables in a disposable directory, enters new user and network namespaces,
and invokes only `TestF2NetworkNamespace`. The test compares its network
namespace with the caller's and requires **only lo** before doing anything.
There is no sudo/nsenter/host fallback. If namespaces/capabilities or TUN access
are denied, stop and report the failure rather than bypassing the guard.

All devices, addresses, foreign-VPN sentinel routes/rules and dummy uplink are
created inside those namespaces. Hard-kill cases run in separate fresh namespaces.
The system D-Bus address is deliberately invalid
to prevent resolvectl from changing the host resolver. No internet connection
or actual remote VPN server is used. At the end, kernel namespace teardown
discards the hard-kill fixture's deliberately retained rules. The tests compare
complete rule and route snapshots before/after normal operations and conflicts.

Optional read-only host snapshots before/after the wrapper:

```sh
ip -j -N -4 rule show
ip -j -N -6 rule show
ip -j -N -4 route show table all
ip -j -N -6 route show table all
```

Passing this test confirms isolated routing lifecycle and conflict behavior;
it does not confirm real uplink traffic, DNS leak protection, Windows runtime,
or general simultaneous operation with Happ in the host namespace.
