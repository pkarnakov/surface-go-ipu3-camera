#!/bin/bash
# On the Surface Go: a live preview of one camera in qcam (libcamera's Qt
# viewer, which scales the picture to its window), for aiming the camera or
# watching AE/AWB/AF settle. Front: 1280x720. Back: full resolution (3264x2448
# asked, 3200x2432 out), the only size before kernel 7.3 (the ov8865 driver
# stalls at others); from 7.3 the third argument picks another, e.g. 1280x720.
# Uses Intel's IPA unless the second argument is "libcamera". Needs a
# graphical session (over ssh: the desktop session's screen) and qcam (sudo dnf install libcamera-qcam); stop other
# apps using the camera. Nothing to undo: close the window.
#   test/preview.sh [front|back] [intel|libcamera] [WxH]   (default: front intel)
set -euo pipefail
# over ssh: show it in the running desktop session (Wayland)
if [ -z "${WAYLAND_DISPLAY:-}${DISPLAY:-}" ]; then
  export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
  [ -S "$XDG_RUNTIME_DIR/wayland-0" ] || { echo "no display and no Wayland session"; exit 1; }
  export WAYLAND_DISPLAY=wayland-0 QT_QPA_PLATFORM=wayland
fi
command -v qcam >/dev/null || { echo "qcam not found: sudo dnf install libcamera-qcam"; exit 1; }
case "${1:-front}" in
  front) ID=CAMF; SIZE=width=1280,height=720;;
  back) ID=CAMR; SIZE=width=3264,height=2448;;
  *) echo "usage: $0 [front|back] [intel|libcamera] [WxH]"; exit 1;;
esac
if [ -n "${3:-}" ]; then
  [[ $3 =~ ^([0-9]+)x([0-9]+)$ ]] || { echo "size: WxH, e.g. 1280x720"; exit 1; }
  SIZE=width=${BASH_REMATCH[1]},height=${BASH_REMATCH[2]}
fi
case "${2:-intel}" in
  intel) export LIBCAMERA_IPA_MODULE_PATH=~/.local/lib/libcamera-ipu3-intel;;
  libcamera) unset LIBCAMERA_IPA_MODULE_PATH;;
  *) echo "usage: $0 [front|back] [intel|libcamera] [WxH]"; exit 1;;
esac
# qcam takes the camera's full name; look it up as cam does
command -v cam >/dev/null || { echo "cam not found: sudo dnf install libcamera-tools"; exit 1; }
CAM=$(cam -l 2>/dev/null | sed -n "s/.*(\(.*$ID\))$/\1/p" | head -1 || true)
[ -n "$CAM" ] || { echo "no camera $ID in cam -l"; exit 1; }
exec qcam -c "$CAM" -s "$SIZE,pixelformat=NV12"
