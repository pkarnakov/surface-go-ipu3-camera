#!/bin/bash
# On the Surface Go: a live view of the IR camera in qv4l2 (v4l-utils' Qt
# viewer). Starts surface-ir.service (sudo; it must be installed, see
# README.md), then opens its v4l2loopback device; press play. The device is a
# camera only while the feed runs, so start this, not qv4l2 alone. Over ssh
# it opens on the desktop session's screen. Nothing to undo: close the
# window, and the feed stops by itself 10 s later.
#   ir/preview.sh
set -euo pipefail
# over ssh: show it in the running desktop session (Wayland)
if [ -z "${WAYLAND_DISPLAY:-}${DISPLAY:-}" ]; then
  export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
  [ -S "$XDG_RUNTIME_DIR/wayland-0" ] || { echo "no display and no Wayland session"; exit 1; }
  export WAYLAND_DISPLAY=wayland-0 QT_QPA_PLATFORM=wayland
fi
command -v qv4l2 >/dev/null || { echo "qv4l2 not found: sudo dnf install qv4l2"; exit 1; }
systemctl cat surface-ir.service >/dev/null 2>&1 || { echo "surface-ir.service not installed: cd ir && sudo make install"; exit 1; }
sudo systemctl start surface-ir.service
DEV=$(grep -lx 'Surface IR' /sys/class/video4linux/video*/name | head -1 || true)
[ -n "$DEV" ] || { echo "no v4l2loopback device \"Surface IR\""; exit 1; }
exec qv4l2 -d /dev/"$(basename "$(dirname "$DEV")")"
