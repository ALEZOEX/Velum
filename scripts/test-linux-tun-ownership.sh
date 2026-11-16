#!/bin/bash
set -euo pipefail
project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
[[ $(uname -s) == Linux && $EUID != 0 ]] || { echo 'Run as an ordinary Linux user; no sudo fallback.' >&2; exit 1; }
core_path=${1:-$project_dir/bin/sing-box}
[[ $core_path == /* && -x $core_path ]] || { echo 'Build the pinned FD core: make core' >&2; exit 1; }
host_netns=$(readlink /proc/self/ns/net)
host_mntns=$(readlink /proc/self/ns/mnt)
test_dir=$(mktemp -d -t velum-f2-XXXXXXXX)
trap 'rm -rf -- "$test_dir"' EXIT
build_flags=()
[[ ${VELUM_F2_RACE:-0} != 1 ]] || build_flags=(-race)
(cd "$project_dir/daemon" && go build "${build_flags[@]}" -o "$test_dir/velumd" . && go test "${build_flags[@]}" -c -o "$test_dir/f2.test" .)
cases=${VELUM_F2_CASES:-'wire_roundtrip normal_repeated_dual_stack concurrent_velum_starts foreign_rules_preexisting foreign_during_session partial_rule_failure lost_ack_partial_install eexist_never_adopts modified_identity_refuses_cleanup exclusive_duplicate_rejected corrupt_journal_refuses_cleanup unmarked_residual_not_adopted core_SIGKILL_reconnect guardian_and_core_SIGKILL_independent_recovery daemon_15 daemon_9 data_plane_dns_ipv4_ipv6'}
for test_case in $cases; do
  unshare --user --map-root-user --mount --net --pid --fork --mount-proc --kill-child=KILL /bin/bash -c '
    set -euo pipefail
    [[ $(readlink /proc/self/ns/net) != "$1" && $(readlink /proc/self/ns/mnt) != "$2" ]] || exit 1
    mount --make-rprivate /
    mount -t tmpfs -o mode=0755 tmpfs /run
    exec env VELUM_F2_HOST_NETNS="$1" VELUM_F2_CORE="$3" VELUM_TEST_CORE="$3" VELUM_F2_DAEMON="$4/velumd" DBUS_SYSTEM_BUS_ADDRESS=unix:path=/nonexistent-velum-f2-bus "$4/f2.test" -test.run "^TestF2NetworkNamespace$/$5$" -test.v -test.timeout=120s
  ' velum-f2 "$host_netns" "$host_mntns" "$core_path" "$test_dir" "$test_case"
done
