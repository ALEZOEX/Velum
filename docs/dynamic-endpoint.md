# Linux TUN endpoint changes

Before F10, Velum resolved the profile hostname once, then wrote a numeric
server address into sing-box or Xray and excluded that address from the TUN.
A controlled resolver with a one-second TTL reproduced the stale address on
the F2 daemon. Hysteria2, Reality/Vision and XHTTP all continued carrying
traffic through the old server after the answer changed. No core query for
the new address or change to kernel routing was observed in that experiment.

sing-box 1.12.12 skips its FQDN lookup for a numeric destination
([dialer source](https://github.com/SagerNet/sing-box/blob/v1.12.12/common/dialer/resolve.go)).
The Xray configuration likewise contains a numeric remote VLESS address,
independently of its TLS server name and the local SOCKS bridge
([system dialer](https://github.com/XTLS/Xray-core/blob/v26.10.31/transport/internet/system_dialer.go)).
The experiment used Velum-generated configurations.

## Connection lifecycle

A Linux TUN connection uses one numeric transport address and one uplink.
The daemon resolves both A and AAAA before replacing the connection.
It preserves the original TLS name and checks the selected interface.
Immediately before creating the replacement TUN, the supervisor checks
the bound kernel route and the source address on that interface. It installs
the journaled rules before starting sing-box. Xray starts after the Linux
supervisor reports readiness. A successful route check confirms the local
path. A TLS handshake and data transfer check server reachability.

While the connection runs, the daemon checks the interface and the route to
the pin. Domain profiles are queried again after the minimum relevant DNS
TTL, with a polling interval bounded between five seconds and five minutes.
A DNS error backs off to 10, 20, 40, then 60 seconds. An IP literal only needs
interface checks. The observer holds no network lease and cannot modify
the core, policy rules or journal.

If the pin disappears from the answer set or the uplink changes, the current
session stays in place. A new API status snapshot contains
`endpoint.needsReconnect`, a human-readable `error` and `endpoint.message`.
The endpoint object also exposes the pin, latest successful answer set,
interface, expiry and consecutive DNS error count. A DNS-only failure
preserves the last usable answer. The warning clears on recovery when the
pin and uplink are valid again. A running local core can outlive connectivity
to its server. Use a data-plane check for end-to-end reachability.

An explicit reconnect resolves again, advances to the next advertised
address when the same session has multiple candidates, and replaces the
pin through the F2 supervisor. Validation or DNS failure before teardown
keeps the previous session. A failure after teardown is reported, with
the supervisor performing exact journal-based cleanup. Replacement can
interrupt application traffic. Velum does not provide a persistent
kill switch between sessions. Core-crash reconnect remains bounded by
the daemon's retry budget. Manual disconnect supersedes stale work.

## Why reconnect

| Approach | Operational trade-off |
| --- | --- |
| Edit live route exclusions when DNS changes | Both transports use immutable numeric configurations. Editing only routes leaves the old dialer active. Coordinating two cores and rolling back mid-update adds another failure path. |
| Observe the endpoint and replace the session on request | Reuses one F2 writer, bounded DNS and a full validation/cleanup cycle. A user may need to reconnect after a move. |
| Separate controller for automatic live handover | Needs acknowledgement from each transport, overlapping leases and a crash-safe commit across routing and core configuration. Useful if uninterrupted migration becomes a requirement. |

## Limits and verification

- The resolver reads local hosts entries and configured numeric nameservers
  with search domains and ndots. A system DNS stub can provide split DNS.
  Custom NSS plugins, mDNS and direct discovery of per-link resolvers are
  outside this resolver. If the only nameserver requires a failed transport,
  refresh can report a DNS error until that resolver becomes reachable. A
  systemd-resolved stub can have this dependency when its per-link DNS
  points into the existing TUN.
- The physical exception matches UID 0 and one exact address. Other root
  processes can also match it. F2 retains its assumptions about competing
  privileged writers and cannot guarantee an atomic handover against them.
- Transport changes are scoped to Linux TUN. Windows and proxy-only
  connections retain their platform resolver and do not run this observer.
- `scripts/test-linux-dynamic-endpoint.py` uses a private resolver, peer,
  mount and network namespaces, real cores, HTTP payloads and kernel route
  checks. It refuses host root or a shared namespace. Use the same pinned
  binaries as [the F2 tests](linux-tun-ownership.md). Optional binary
  overrides are `VELUM_TEST_CORE` and `VELUM_TEST_DAEMON`.
