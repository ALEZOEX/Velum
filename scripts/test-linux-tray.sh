#!/bin/bash
# Explicitly opt-in UI test: isolated bus and own Waybar, no daemon/VPN startup.
set -euo pipefail
if [[ ${1:-} != --isolated-session ]]; then
  echo 'Usage: scripts/test-linux-tray.sh --isolated-session' >&2
  echo 'Runs a test GUI and temporary Waybar on this Hyprland display, using a private D-Bus session.' >&2
  exit 2
fi
for tool in flutter dbus-run-session waybar gdbus jq timeout hyprctl; do
  command -v "$tool" >/dev/null
done
if [[ ${XDG_CURRENT_DESKTOP:-} != *Hyprland* || -z ${WAYLAND_DISPLAY:-} || ! -S ${XDG_RUNTIME_DIR:-}/${WAYLAND_DISPLAY} ]]; then
  echo 'A working Hyprland Wayland session is required.' >&2
  exit 2
fi
repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
smoke_dir=$(mktemp -d /tmp/velum-f9-smoke.XXXXXX)
printf '%s\n' '{"layer":"top","position":"bottom","height":24,"modules-right":["tray"],"tray":{"spacing":4}}' > "$smoke_dir/waybar.json"
printf '%s\n' 'window#waybar { background: #222222; }' > "$smoke_dir/waybar.css"
# Keep logs/results for diagnosis; the harness cleans up its own child panel.
cd "$repo_dir/app"
flutter build linux --release --target tool/tray_lifecycle_smoke.dart
cp -a build/linux/x64/release/bundle "$smoke_dir/bundle"
echo "Test logs/results: $smoke_dir"
set +e
timeout --kill-after=5 90 dbus-run-session -- env GDK_BACKEND=wayland \
  VELUM_TRAY_SMOKE=1 VELUM_TRAY_SMOKE_DIR="$smoke_dir" \
  "$smoke_dir/bundle/velum" > "$smoke_dir/runtime.log" 2>&1
result_code=$?
set -e
cat "$smoke_dir/runtime.log"
if (( result_code != 0 )); then
  echo "Test process failed/timed out: $result_code. Inspect $smoke_dir" >&2
  exit "$result_code"
fi
jq -e '.passed == true and .vpnInitialized == false and (.checks | length == 6)' "$smoke_dir/results.json"
