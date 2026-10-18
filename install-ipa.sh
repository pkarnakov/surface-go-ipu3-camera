#!/bin/bash
# On the Surface Go (Fedora 43, libcamera 0.5.2): install build-ipa.sh's
# output for this user in ~/.local/lib/libcamera-ipu3-intel, with
# ov5693.aiqb -> the tuning variant (TUNING, default MSHW0140; MSHW0150
# looked the same on a Surface Go 3), and a WirePlumber drop-in that points
# libcamera there (LIBCAMERA_IPA_MODULE_PATH: searched before the system's
# IPAs). Restarts WirePlumber. No root needed.
# With it the back camera (ov8865) is gone: there is no Intel tuning for it,
# its IPA init fails.
#   [TUNING=MSHW0150] ./install-ipa.sh
#   ./install-ipa.sh --uninstall
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
case "$PWD" in *[[:space:]]*) echo "the repository path must not contain spaces"; exit 1;; esac
D=~/.local/lib/libcamera-ipu3-intel
DROPIN=~/.config/systemd/user/wireplumber.service.d/50-ipu3-intel.conf
if [ "${1:-}" = --uninstall ]; then
  rm -f $DROPIN
  rm -rf $D
  systemctl --user daemon-reload
  systemctl --user restart wireplumber
  echo "uninstalled; libcamera's own IPA again"
  exit 0
fi
TUNING=${TUNING:-MSHW0140}
# the module is built against libcamera 0.5.2's IPA interface
v=$(rpm -q --qf '%{VERSION}' libcamera 2>/dev/null || true)
[ "$v" = 0.5.2 ] || { echo "needs libcamera 0.5.2 (installed: ${v:-none}); see install-libcamera.sh"; exit 1; }
[ -f out/ipa/intel-ipu3-ipa.so ] || { echo "run ./build-ipa.sh first"; exit 1; }
[ -f out/ipa/ov5693_$TUNING.aiqb ] || { echo "no tuning $TUNING"; exit 1; }
rm -rf $D.new && mkdir -p $(dirname $D)
cp -a out/ipa $D.new
ln -sfn ov5693_$TUNING.aiqb $D.new/ov5693.aiqb
rm -rf $D && mv $D.new $D
mkdir -p $(dirname $DROPIN)
rm -f $DROPIN   # a symlink would be written through
cp wireplumber/50-ipu3-intel.conf $DROPIN
systemctl --user daemon-reload
systemctl --user restart wireplumber; sleep 5
systemctl --user is-active wireplumber
systemctl --user show wireplumber -p Environment
echo "installed in $D (tuning $TUNING)"
