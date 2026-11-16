# Pinned Linux core adapter

`sing-box-1.12.12-tun-fd.patch` exposes sing-tun's existing `FileDescriptor`
option through sing-box JSON. The daemon passes FD 3 only on Linux TUN starts.
No routing or cleanup code from sing-tun is used in this mode. The patch adds
one JSON field and forwards it; sing-tun itself remains unmodified.

This is necessary because stock 1.12.12 has no JSON FD option and setting
`auto_route=false` still installs/removes an IPv6 rule by priority. A core
built without the adapter rejects the configuration before any TUN is created;
there is deliberately no fallback to unsafe native routing.

Build from the pinned Go module with `make core` on Linux (Python 3 and patch
required). The script copies source to a temporary directory, applies with
`--fuzz=0`, and never edits the Go module cache. It checks the expected version
and Go module checksum. The original GPL license remains applicable; upstream
source and this patch are available to reproduce the binary. Windows continues
to build stock sing-box. Re-audit FD-mode lifecycle on every dependency update;
a version bump must not silently retain this adapter without verification.
