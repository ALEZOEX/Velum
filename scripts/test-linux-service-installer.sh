#!/bin/bash
# An unprivileged user namespace, private mounts/PIDs/network; no host services.
set -euo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
for tool in unshare bwrap python3 ip; do
  command -v "$tool" >/dev/null || { printf 'Required isolation tool missing: %s\n' "$tool" >&2; exit 1; }
done
host_netns=$(readlink /proc/self/ns/net)
if [[ ${1:-} != --inside ]]; then
  if [[ ${1:-} == --disposable-ci ]]; then
    [[ $EUID == 0 && ${GITHUB_ACTIONS:-} == true && ${RUNNER_ENVIRONMENT:-} == github-hosted ]] || exit 1
    /usr/bin/systemd-detect-virt --vm --quiet || exit 1
    exec unshare --mount --mount-proc --pid --fork --net \
      /bin/bash "${BASH_SOURCE[0]}" --inside "$host_netns"
  fi
  [[ $# == 0 && $EUID != 0 ]] || { printf 'Run as an ordinary user; no sudo fallback.\n' >&2; exit 1; }
  exec unshare --user --map-auto --map-root-user --mount --mount-proc --pid --fork --net \
    /bin/bash "${BASH_SOURCE[0]}" --inside "$host_netns"
fi
[[ $# == 2 && $(readlink /proc/self/ns/net) != "$2" && $EUID == 0 ]] || exit 1
ip link set lo up  # Only the new, verified network namespace.
extra=()
[[ ! -d /usr/lib64 || -L /usr/lib64 ]] || extra+=(--ro-bind /usr/lib64 /usr/lib64)
exec bwrap --die-with-parent --unshare-pid \
  --cap-add CAP_CHOWN --cap-add CAP_FOWNER --cap-add CAP_DAC_OVERRIDE \
  --cap-add CAP_SETUID --cap-add CAP_SETGID --tmpfs / \
  --ro-bind /usr/bin /usr/bin --ro-bind /usr/lib /usr/lib "${extra[@]}" \
  --symlink usr/bin /bin --symlink usr/bin /sbin \
  --symlink usr/lib /lib --symlink "$(readlink /lib64 || printf usr/lib64)" /lib64 \
  --dir /usr/local/lib --dir /usr/share/polkit-1/actions \
  --dir /home --dir /tmp --dir /etc --dir /run \
  --ro-bind "$project_dir" /run/source \
  --proc /proc --dev /dev --dir /dev/net --dev-bind /dev/null /dev/net/tun \
  --ro-bind "$project_dir/scripts/tests/systemctl-fixture.py" /usr/bin/systemctl \
  --chdir / -- /usr/bin/python3 -I /run/source/scripts/tests/linux_service_installer_test.py
