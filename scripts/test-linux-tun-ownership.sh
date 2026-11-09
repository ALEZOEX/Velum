#!/usr/bin/env bash
# Never runs networking tests in the caller's network namespace.
set -euo pipefail
project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
if [[ $(uname -s) != Linux || $EUID == 0 ]]; then
  echo 'Run as an ordinary Linux user; do not use sudo.' >&2
  exit 1
fi
core_path="$project_dir/bin/sing-box"
[[ -x $core_path ]] || { echo 'Build pinned core first: make core' >&2; exit 1; }
host_netns=$(readlink /proc/self/ns/net)
test_dir=$(mktemp -d -t velum-f2-XXXXXXXX)
trap 'rm -rf -- "$test_dir"' EXIT
(
  cd "$project_dir/daemon"
  go build -o "$test_dir/velumd" .
  go test -c -o "$test_dir/f2.test" .
)
# Hard kills may intentionally leave rules. Give those cases separate
# namespaces; kernel namespace teardown is the only fixture cleanup needed.
for test_case in 'free.*|occupied.*|partial.*|repeated.*|velumd_terminated' 'velumd_killed' 'core_SIGKILL.*'; do
  # No fallback to sudo/nsenter or to testing in the main network namespace.
  unshare --user --map-root-user --net env \
    VELUM_F2_HOST_NETNS="$host_netns" \
    VELUM_F2_CORE="$core_path" VELUM_F2_DAEMON="$test_dir/velumd" \
    DBUS_SYSTEM_BUS_ADDRESS=unix:path=/nonexistent-velum-f2-bus \
    "$test_dir/f2.test" -test.run "^TestF2NetworkNamespace$/($test_case)$" -test.v -test.timeout=90s
done
