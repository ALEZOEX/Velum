#!/usr/bin/env bash
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
[[ $(uname -s) == Linux && $EUID == 0 ]] || { printf 'Run with sudo on Linux.\n' >&2; exit 1; }
[[ $# == 0 ]] || { printf 'Usage: sudo ./scripts/uninstall-linux-service.sh\n' >&2; exit 1; }
[[ ! -L /run/velum-install.lock ]] || { printf 'Refusing symlink at installer lock.\n' >&2; exit 1; }
exec 9>/run/velum-install.lock
flock -n 9 || { printf 'Another Velum installation or removal is running.\n' >&2; exit 1; }
unit_path=/etc/systemd/system/velum.service
install_dir=/usr/local/lib/velum
config_path=/etc/velum
for target in "$unit_path" "$install_dir" "$config_path" "$config_path/token"; do
  [[ ! -L $target ]] || { printf 'Refusing symlink: %s\n' "$target" >&2; exit 1; }
  if [[ -e $target && $(stat -c %u "$target") != 0 ]]; then
    printf 'Refusing non-root-owned path: %s\n' "$target" >&2; exit 1
  fi
done
if [[ -f $unit_path ]]; then
  unit=$(<"$unit_path")
  [[ $unit == *'ExecStart=/usr/local/lib/velum/velumd '* ]] || { printf 'The installed unit is not managed by this installer.\n' >&2; exit 1; }
  systemctl disable --now velum.service
fi
rm -f -- "$unit_path" "$config_path/token"
rm -rf -- "$install_dir"
if [[ -d $config_path ]]; then rmdir -- "$config_path" 2>/dev/null || true; fi
systemctl daemon-reload
systemctl reset-failed velum.service 2>/dev/null || true
printf 'Velum system service removed. User profiles, settings and GUI token are preserved.\n'
