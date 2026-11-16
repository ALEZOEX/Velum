# Disposable systemd recovery verification

The wrapper uses an unprivileged QEMU/KVM process, a qcow2 overlay and a read-only
NoCloud ISO. There is **no virtual NIC**, TAP, bridge, host port forwarding or
shared writable host filesystem. All network operations, systemd installation,
signals and test accounts/paths belong to the guest. The host installer is never
run. The base image is not modified; only the temporary overlay is writable.

Requirements: QEMU/KVM access, qemu-img, genisoimage, Python3 and a verified Debian13
genericcloud amd64 image. A statically built FD core and daemon avoid depending
on the host glibc version. The fixture reads the real unit template from
`install-linux-service.sh`; it does not import F15's installer changes.

```sh
CGO_ENABLED=0 python3 scripts/build-linux-core.py --output /tmp/velum-f2-static-core
(cd daemon && CGO_ENABLED=0 go build -o /tmp/velum-f2-static-daemon .)
python3 scripts/test-linux-systemd-vm.py \
  --image /path/to/verified/debian-13-genericcloud-amd64.qcow2 \
  --core /tmp/velum-f2-static-core --daemon /tmp/velum-f2-static-daemon \
  --log /tmp/velum-systemd.log
```

Download images/checksums from the [Debian cloud archive](https://cloud.debian.org/images/cloud/trixie/).
Verify the downloaded image against its SHA512SUMS (and the signature when
applicable) before supplying it. The tested image SHA512 was:

```text
37cb32b320820417eb04b335afcf489bfb4cecce4a957190d09cb2bffbe02b56a1cadd62d78c6ead92aa7839d5ea65e4260f994bbb4b54490df59fdf11ee1d97
```

The guest asserts QEMU/KVM virtualization, an explicit disposable marker and no
external NIC before any mutation. It configures a dummy uplink, IPv4/IPv6 foreign
VPN sentinels, root-private token and the actual production service unit.
Serial getty is masked **only inside the guest**: otherwise getty's startup
hangup invalidates an already open test output FD and Python can exit120 without
a result. Network wait-online may time out because the VM intentionally has no
NIC; this boot fixture condition is separate from Velum's tests.

The suite exercises:

- Real ExecStartPre/ExecStopPost, RuntimeDirectory mode/preservation and normal
  TUN connection/stop.
- Direct-return ownership on the guest kernel and rejection of a UID1000
  source-bound bypass.
- Foreign IPv4/IPv6 rules at the same priority and routes in the same table
  surviving service stop.
- SIGSTOP followed by SIGKILL of the entire service cgroup: all Go cleanup is
  prevented. ExecStopPost must clean before any replacement daemon starts.
- Default Restart=on-failure and a fresh connection after cgroup death.
- A fixture-only drop-in suppresses StopPost for one kill to deliberately retain
  journal/rules. Restoring the production hook and corrupting that journal must
  block startup without mutation. After restoring the known original journal,
  production ExecStartPre must clean it **before** main can run: a second Pre
  assertion checks this, preventing main's own recovery from masking a broken hook.
- Repeated connect/disconnect and final service removal inside the VM.

A missing result, failed assertion, VM timeout, denied KVM or failed isolation
returns failure; there is no host systemd or host TUN fallback. The wrapper leaves
its requested diagnostic log and removes its own temporary overlay/ISO. It does
not remove user images or logs.

The network CI job separately runs real ownership/crash and data-plane tests in
user/network/mount/PID namespaces. It permits user namespaces via an AppArmor
sysctl **only in a disposable GitHub-hosted runner**, guarded by
`RUNNER_ENVIRONMENT=github-hosted`. No such sysctl is run on the developer's host.

Recorded result: **PASS**, all eight scenarios in Debian13.7 with systemd257.13
and kernel6.12.117+deb13-cloud-amd64. The result marker reported success and the
guest exited0. The developer host's network/systemd and Happ were not touched.
This does not validate every distribution, host TUN, desktop DNS or Windows.
