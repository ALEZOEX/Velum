#!/bin/bash
# Private user/mount/PID/network namespaces and chroot; no host services.
set -euo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
for tool in unshare mount chroot python3 ip; do
  command -v "$tool" >/dev/null || { printf 'Required isolation tool missing: %s\n' "$tool" >&2; exit 1; }
done
if [[ ${1:-} != --inside ]]; then
  host_netns=$(readlink /proc/self/ns/net)
  host_mntns=$(readlink /proc/self/ns/mnt)
  test_root=$(mktemp -d -t velum-f15-root-XXXXXXXX)
  # Only remove the empty mount point after namespace teardown; never rm -rf.
  trap 'rmdir -- "$test_root"' EXIT
  if [[ ${1:-} == --disposable-ci ]]; then
    [[ $EUID == 0 && ${GITHUB_ACTIONS:-} == true && ${RUNNER_ENVIRONMENT:-} == github-hosted ]] || exit 1
    /usr/bin/systemd-detect-virt --vm --quiet || exit 1
    unshare --user --map-users=0:0:65536 --map-groups=0:0:65536 \
      --mount --mount-proc --pid --fork --net \
      /bin/bash "${BASH_SOURCE[0]}" --inside "$host_netns" "$host_mntns" "$test_root"
    exit $?
  fi
  [[ $# == 0 && $EUID != 0 ]] || { printf 'Run as an ordinary user; no sudo fallback.\n' >&2; exit 1; }
  unshare --user --map-auto --map-root-user --mount --mount-proc --pid --fork --net \
    /bin/bash "${BASH_SOURCE[0]}" --inside "$host_netns" "$host_mntns" "$test_root"
  exit $?
fi
[[ $# == 4 && $EUID == 0 && $(readlink /proc/self/ns/net) != "$2" && $(readlink /proc/self/ns/mnt) != "$3" ]] || exit 1
test_root=$4
mount --make-rprivate /
mount -t tmpfs -o mode=0755 tmpfs "$test_root"
ip link set lo up  # Only the new, verified network namespace.
mkdir -p "$test_root"/{usr/bin,usr/lib,usr/local/lib,usr/share/polkit-1/actions,home,tmp,etc,run/source,proc,dev/net}
readonly_bind() {
  mount --bind "$1" "$2"
  mount -o remount,bind,ro,nosuid,nodev "$2"
}
readonly_bind /usr/bin "$test_root/usr/bin"
readonly_bind /usr/lib "$test_root/usr/lib"
for location in /bin /sbin /lib /lib64 /usr/lib64 /usr/sbin; do
  if [[ -L $location ]]; then
    ln -s -- "$(readlink "$location")" "$test_root$location"
  elif [[ -d $location ]]; then
    mkdir -p "$test_root$location"
    readonly_bind "$location" "$test_root$location"
  fi
done
readonly_bind "$project_dir" "$test_root/run/source"
readonly_bind "$project_dir/scripts/tests/systemctl-fixture.py" "$test_root/usr/bin/systemctl"
mount -t proc proc "$test_root/proc"
for device in null zero random urandom; do
  touch "$test_root/dev/$device"
  mount --bind "/dev/$device" "$test_root/dev/$device"
done
touch "$test_root/dev/net/tun"
mount --bind /dev/null "$test_root/dev/net/tun"
exec chroot "$test_root" /usr/bin/python3 -I /run/source/scripts/tests/linux_service_installer_test.py
