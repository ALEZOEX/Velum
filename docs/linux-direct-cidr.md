# Direct CIDR with Linux TUN

## Confirmed cause

With `198.19.0.0/24` excluded, the generated configuration correctly selected
outbound `direct` after sniff/DNS rules. `default_interface=lab0` bound the real
TCP socket to the physical uplink. The application still entered TUN for policy
classification; only the VPN server IP was in `route_exclude_address`.

Packet capture in two isolated namespaces showed:

```text
client lab0 Out 198.18.0.1 -> 198.19.0.2 SYN
peer   lab1 In  198.18.0.1 -> 198.19.0.2 SYN
peer   lab1 Out 198.19.0.2 -> 198.18.0.1 SYN-ACK
client lab0 In  198.19.0.2 -> 198.18.0.1 SYN-ACK
# No outgoing ACK; SYN retransmits until core timeout.
```

The server was listening, received SYN and returned the correct response.
`ip route get 198.19.0.2 oif lab0` chose the physical uplink/source, but the
unbound reverse lookup chose table27841/velum0. Both `all` and `lab0`
`rp_filter` were1. Changing **only** rp_filter inside the disposable namespace
to0 made the same HTTP request succeed. No such sysctl change is made by Velum.
The failure was also present on the original main with stock sing-box.

Linux's [`__fib_validate_source()`](https://github.com/torvalds/linux/blob/v6.12/net/ipv4/fib_frontend.c)
constructs a reverse flow with source=local physical address,
destination=remote server and root net UID, then checks its device against the
incoming interface. This explains why the bound socket's correct outgoing
path alone did not suffice.

## Fix and scope

For plain direct CIDR rules, the Linux supervisor now journals exact policy
pairs at reserved priority27841, before ordinary TUN selectors:

1. Source=one physical interface IP (/32 or /128), destination=direct CIDR,
   UID=0: lookup main.
2. Same source/destination/UID: unreachable if that lookup had no usable route.

The actual core and the kernel reverse-path check can use these rules. An
ordinary user's source-bound socket cannot use the new bypass. Conditional,
domain and proxy rules are not widened into CIDR rules. The application leg
still enters TUN, so earlier reject/proxy rules and DNS hijack retain their
precedence. There is deliberately no wholesale addition of CIDRs to
`route_exclude_address`: that would bypass DNS and application policy.

IPv4/IPv6 use the same source-scoped model; the main-table default and other
VPN's rules/routes are never edited by this fix. All added rules carry F2
session identity and use its existing write-ahead journal/exact recovery.
The first ordinary TUN priority moves to27842; the reserved interval/table
remain unchanged. Large valid CIDR sets use an explicit2048-object limit and
1MiB journal bound; oversized plans are refused before mutation.

When direct routing disappears, the request fails within the existing bounded
core dial timeout (5s), rather than falling back to VPN. The route check from
the physical source returns unreachable. Already cached socket routes may
still send SYNs physically before timing out; no instant-failure guarantee is
made. The test requires core-reported failure before its8s client deadline,
not a successful request or a client timeout.

## Tests

The full two-namespace suite now passes:

- Strict rp_filter1 on the fixture uplink; no reverse-path counter increase
  during successful direct requests.
- Different, duplicate and overlapping IPv4/IPv6 CIDRs.
- Direct server-visible physical source, and nonexcluded server-visible VPN
  source in the same connection.
- UDP/TCP DNS hijack for addresses **inside** excluded CIDRs, both IP families.
- Missing physical defaults: bounded direct failure while VPN traffic survives.
- Earlier block rules win over CIDR exclusions.
- Full rule/all-table route snapshots restored after disconnect/SIGTERM.
- Actual Hysteria2, Reality/Vision and XHTTP traffic.

A separate fixture issue was found: IPv6 link-local DAD completed after the
initial route snapshot. The wrapper now waits for DAD before taking baseline;
it still compares complete route snapshots and does not ignore added routes.

Limits: root/CAP_NET_ADMIN interference remains outside F2's strict guarantee;
privileged source-bound sockets can select main. Physical IP changes require
reconnect to refresh these source rules. Dynamic endpoint/interface handling is
tracked separately as F10. Windows configuration is unchanged.
