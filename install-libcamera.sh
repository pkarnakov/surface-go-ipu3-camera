#!/bin/bash
# On the Surface Go (Fedora 43): install build-libcamera.sh's RPMs for the
# libcamera subpackages already installed, lock them (dnf versionlock) so
# updates don't bring the bugs back, restart WirePlumber, and check that
# 640x360 streams instead of aborting. Asks for the sudo password.
#   ./install-libcamera.sh
# Undo: sudo dnf versionlock delete 'libcamera*'; sudo dnf distro-sync 'libcamera*'
#       systemctl --user restart wireplumber
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
R=out/libcamera-rpms
ls $R/libcamera-0.5.2-5.2.ipu3.fc43.x86_64.rpm >/dev/null
pkgs=()
for n in $(rpm -qa --qf '%{NAME}\n' 'libcamera*' | sort -u); do
  f=$R/$n-0.5.2-5.2.ipu3.fc43.x86_64.rpm
  if [ -f $f ]; then pkgs+=("./$f"); fi
done
printf '%s\n' "${pkgs[@]}"
locked=$(dnf versionlock list 2>/dev/null | sed -n 's/^Package name: \(libcamera.*\)/\1/p' | sort -u)
if [ -n "$locked" ]; then sudo dnf versionlock delete $locked; fi
sudo dnf -y install "${pkgs[@]}"
sudo dnf versionlock add $(rpm -qa 'libcamera*')
rpm -qa 'libcamera*' | sort
systemctl --user restart wireplumber; sleep 5
systemctl --user is-active wireplumber
CAM=$(cam -l 2>/dev/null | grep -m1 CAMF | cut -d: -f1)
for s in 640x360 1280x720; do
  rc=0; timeout -k 3 20 cam -c "$CAM" --capture=10 --stream width=${s%x*},height=${s#*x} >/tmp/cam.$$ 2>&1 </dev/null || rc=$?
  echo "$s: rc=$rc (134 = abort), $(grep -c 'fps)' /tmp/cam.$$) frames"
done
rm -f /tmp/cam.$$
