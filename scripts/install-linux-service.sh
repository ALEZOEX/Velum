#!/usr/bin/env bash
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
umask 077

usage() {
  cat <<'EOF'
Usage: sudo ./scripts/install-linux-service.sh [--user USER] [--config-dir DIR]
       [--bin-dir DIR] [--interface NAME] [--no-start]
Installs the reviewed Velum binaries as a privileged system TUN service.
The user's existing token is copied; user profiles are not modified.
EOF
}
fail() { printf 'Velum: %s\n' "$*" >&2; exit 1; }
if [[ ${1:-} == --help || ${1:-} == -h ]]; then usage; exit 0; fi
[[ $(uname -s) == Linux ]] || fail 'Linux is required.'
[[ $EUID == 0 ]] || fail 'Run this installer with sudo or pkexec after reviewing it.'
project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
client_user=${SUDO_USER:-${PKEXEC_UID:-}}
config_dir=
bin_dir=$project_dir/bin
interface_name=
start_service=yes
while (($#)); do
  case $1 in
    --user|--config-dir|--bin-dir|--interface)
      (($# >= 2)) || fail "Missing value for $1"
      case $1 in
        --user) client_user=$2 ;;
        --config-dir) config_dir=$2 ;;
        --bin-dir) bin_dir=$2 ;;
        --interface) interface_name=$2 ;;
      esac
      shift 2 ;;
    --no-start) start_service=no; shift ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; fail "Unknown option: $1" ;;
  esac
done
for command in systemctl getent python3 install mktemp ss flock; do
  command -v "$command" >/dev/null || fail "Required command not found: $command"
done
[[ ! -L /run/velum-install.lock ]] || fail 'Refusing symlink at the installer lock.'
exec 9>/run/velum-install.lock
flock -n 9 || fail 'Another Velum installation or removal is running.'
[[ -d /run/systemd/system ]] || fail 'systemd must be running as the system manager.'
[[ -c /dev/net/tun ]] || fail '/dev/net/tun is unavailable.'
[[ -n $client_user ]] || fail 'Specify the unprivileged GUI user with --user.'
passwd_entry=$(getent passwd "$client_user") || fail 'GUI user does not exist.'
IFS=: read -r client_user _ client_uid _ _ client_home _ <<< "$passwd_entry"
[[ $client_uid =~ ^[0-9]+$ && $client_uid != 0 ]] || fail 'The GUI user must not be root.'
[[ $client_home == /* && $client_home != / ]] || fail 'Invalid GUI home directory.'
config_dir=${config_dir:-$client_home/.config/velum}
[[ $config_dir == /* && $bin_dir == /* ]] || fail 'Configuration and binary directories must be absolute paths.'
[[ -z $interface_name || $interface_name =~ ^[a-zA-Z0-9_.:-]{1,64}$ ]] || fail 'Invalid interface name.'
if [[ -n $interface_name ]]; then
  ip link show dev "$interface_name" >/dev/null 2>&1 || fail 'Requested outbound interface does not exist.'
fi
for binary in velumd sing-box; do
  [[ -f $bin_dir/$binary && -x $bin_dir/$binary && ! -L $bin_dir/$binary ]] || fail "Missing regular executable: $bin_dir/$binary"
done
if [[ -e $bin_dir/xray ]]; then
  [[ -f $bin_dir/xray && -x $bin_dir/xray && ! -L $bin_dir/xray ]] || fail 'xray must be a regular executable.'
fi
validate_token() {
python3 - "$config_dir/token" "$client_uid" "${1:-}" <<'PY'
import os, stat, sys, tempfile
path, uid = sys.argv[1], int(sys.argv[2])
try:
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != uid or info.st_mode & 0o077 or info.st_size > 256:
            raise ValueError()
        token = stream.read(257).strip()
        if not 32 <= len(token) <= 256 or any(c < 33 or c > 126 for c in token):
            raise ValueError()
    if sys.argv[3]:
        target = sys.argv[3]
        temporary = None
        try:
            out, temporary = tempfile.mkstemp(prefix='.token-', dir=os.path.dirname(target))
            with os.fdopen(out, 'wb') as writer:
                writer.write(token + b'\n')
                writer.flush()
                os.fsync(writer.fileno())
            os.replace(temporary, target)
        finally:
            if temporary and os.path.exists(temporary):
                os.unlink(temporary)
except (OSError, ValueError):
    sys.exit('Velum: token must be a private regular file owned by the GUI user. Run scripts/init-client.py as that user first.')
PY
}
validate_token

unit_path=/etc/systemd/system/velum.service
install_dir=/usr/local/lib/velum
config_path=/etc/velum
for directory in /usr/local/lib /etc/systemd/system; do
  [[ -d $directory && ! -L $directory && $(stat -c %u "$directory") == 0 ]] || fail "Untrusted installation directory: $directory"
  [[ $(( $(stat -c %a "$directory") % 100 / 10 & 2 )) == 0 && $(( $(stat -c %a "$directory") % 10 & 2 )) == 0 ]] || fail "Installation directory is writable by non-root users: $directory"
done
for directory in "$install_dir" "$config_path"; do
  if [[ -e $directory || -L $directory ]]; then
    [[ -d $directory && ! -L $directory && $(stat -c %u "$directory") == 0 ]] || fail "Refusing untrusted path: $directory"
    [[ $(( $(stat -c %a "$directory") % 100 / 10 & 2 )) == 0 && $(( $(stat -c %a "$directory") % 10 & 2 )) == 0 ]] || fail "Refusing writable path: $directory"
  fi
done
[[ ! -L $unit_path && ! -L $config_path/token ]] || fail 'Refusing a symlink at a service-owned file.'
was_active=no
was_enabled=no
systemctl is-active --quiet velum.service && was_active=yes
systemctl is-enabled --quiet velum.service 2>/dev/null && was_enabled=yes
if [[ $start_service == yes && $was_active == no && -n $(ss -H -ltn 'sport = :27841') ]]; then
  fail 'Port 27841 is occupied. Stop the previous Velum proxy daemon before starting the system service.'
fi

stage=$(mktemp -d /usr/local/lib/.velum-install.XXXXXXXX)
backup=$(mktemp -d /etc/.velum-backup.XXXXXXXX)
binary_backup=$(mktemp -d /usr/local/lib/.velum-backup.XXXXXXXX)
changed=no
committed=no
config_existed=no
[[ -d $config_path ]] && config_existed=yes
cleanup() {
  local code=$?
  trap - EXIT
  if [[ $committed != yes && $changed == yes ]]; then
    printf 'Velum: installation failed; restoring the previous service files.\n' >&2
    systemctl stop velum.service >/dev/null 2>&1 || true
    rm -rf -- "$install_dir"
    [[ ! -d $binary_backup/binaries ]] || mv -- "$binary_backup/binaries" "$install_dir"
    if [[ -f $backup/unit ]]; then cp -p -- "$backup/unit" "$unit_path"; else rm -f -- "$unit_path"; fi
    if [[ -f $backup/token ]]; then cp -p -- "$backup/token" "$config_path/token"; else rm -f -- "$config_path/token"; fi
    [[ $config_existed == yes ]] || rmdir -- "$config_path" 2>/dev/null || true
    systemctl daemon-reload >/dev/null 2>&1 || true
    if [[ $was_enabled == yes ]]; then systemctl enable velum.service >/dev/null 2>&1 || true; else systemctl disable velum.service >/dev/null 2>&1 || true; fi
    [[ $was_active == no ]] || systemctl start velum.service >/dev/null 2>&1 || true
  fi
  rm -rf -- "$stage" "$backup" "$binary_backup"
  exit "$code"
}
trap cleanup EXIT
install -m 0755 -o root -g root "$bin_dir/velumd" "$stage/velumd"
install -m 0755 -o root -g root "$bin_dir/sing-box" "$stage/sing-box"
xray_arg=
if [[ -f $bin_dir/xray ]]; then
  install -m 0755 -o root -g root "$bin_dir/xray" "$stage/xray"
  xray_arg=' --xray /usr/local/lib/velum/xray'
fi
install -m 0755 -o root -g root "${BASH_SOURCE[0]}" "$stage/install-service.sh"
if [[ -f "$project_dir/scripts/uninstall-linux-service.sh" ]]; then
  install -m 0755 -o root -g root "$project_dir/scripts/uninstall-linux-service.sh" "$stage/uninstall-service.sh"
fi
if [[ -f "$project_dir/packaging/linux/velum-service-control" ]]; then
  install -m 0755 -o root -g root "$project_dir/packaging/linux/velum-service-control" "$stage/velum-service-control"
fi
chmod 0755 "$stage"
[[ ! -f $unit_path ]] || cp -p -- "$unit_path" "$backup/unit"
[[ ! -f $config_path/token ]] || cp -p -- "$config_path/token" "$backup/token"
interface_arg=
[[ -z $interface_name ]] || interface_arg=" --interface $interface_name"
cat > "$backup/new-unit" <<EOF
[Unit]
Description=Velum network service
After=network-online.target
Wants=network-online.target
ConditionPathExists=/dev/net/tun

[Service]
Type=simple
User=root
Group=root
ExecStart=/usr/local/lib/velum/velumd --tun --core /usr/local/lib/velum/sing-box --token-file /etc/velum/token$xray_arg$interface_arg
Restart=on-failure
RestartSec=2
TimeoutStopSec=12
KillMode=control-group
RuntimeDirectory=velum
RuntimeDirectoryMode=0700
Environment=TMPDIR=/run/velum
UMask=0077
NoNewPrivileges=yes
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
DevicePolicy=closed
DeviceAllow=/dev/net/tun rw
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
# Stop only our existing system service; never kill another process by port/name.
changed=yes
if [[ $was_active == yes ]]; then systemctl stop velum.service; fi
[[ ! -d $install_dir ]] || mv -- "$install_dir" "$binary_backup/binaries"
mv -- "$stage" "$install_dir"
install -d -m 0700 -o root -g root "$config_path"
validate_token "$config_path/token"
install -m 0644 -o root -g root "$backup/new-unit" "$unit_path"
if [[ -d /usr/share/polkit-1/actions && -f "$project_dir/packaging/linux/app.velum.service.policy" ]]; then
  install -m 0644 -o root -g root "$project_dir/packaging/linux/app.velum.service.policy" /usr/share/polkit-1/actions/app.velum.service.policy
fi
systemctl daemon-reload
if [[ $start_service == yes ]]; then
  systemctl enable velum.service
  systemctl start velum.service
  python3 - "$config_path/token" <<'PY'
import json, sys, time, urllib.error, urllib.request
from pathlib import Path
secret = Path(sys.argv[1]).read_text().strip()
for _ in range(50):
    try:
        request = urllib.request.Request('http://127.0.0.1:27841/v1/status', headers={'Authorization': 'Bearer ' + secret})
        with urllib.request.urlopen(request, timeout=1) as response:
            status = json.load(response)
        if response.status == 200 and status.get('tunAllowed') is True:
            break
    except (OSError, ValueError, urllib.error.HTTPError):
        pass
    time.sleep(.1)
else:
    sys.exit('Velum: the system service did not expose its authenticated TUN API.')
PY
fi
committed=yes
printf 'Velum system service installed for GUI user %s.\n' "$client_user"
if [[ $start_service == yes ]]; then
  printf 'TUN API is ready. Choose TUN in Velum network settings, then connect.\n'
else
  printf 'Service is not started. Start when ready: sudo systemctl enable --now velum.service\n'
fi
