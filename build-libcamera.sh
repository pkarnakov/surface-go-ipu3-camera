#!/bin/bash
# Rebuild Fedora 43's libcamera (0.5.2-5.fc43) with four fixes, as
# Release 5.5.ipu3, into ./out/libcamera-rpms:
# - 0100: no abort when an app (e.g. Chromium) asks for a small 16:9 size
#   such as 640x360. calculateBDSHeight() computes iif.height - 540
#   unsigned; it wraps for IF heights below 540, and std::clamp(lo > hi)
#   aborts under Fedora's _GLIBCXX_ASSERTIONS, taking WirePlumber down.
#   https://gitlab.freedesktop.org/camera/libcamera/-/work_items/366
# - 0101: libcamera's own IPU3 exposure control has no anti-flicker, so under
#   50 Hz lights the picture pulses. Exposure times of 10 ms and more are
#   rounded down to whole 10 ms periods, analog gain making up. Only
#   matters with libcamera's IPA (Intel's IPA does its own, see build-ipa.sh).
# - 0102: the Surface Go 3's cameras (ov5693, ov8865) read out mirrored, and
#   the firmware only has a rotation to say so: on that model (DMI) the
#   sensors count as mounted mirrored, and libcamera sets their horizontal
#   flip. The ov5693's flip shifts its Bayer order without its driver
#   saying so; 0102 tells libcamera.
# - 0103: the IPU3 pipeline gave the ImgU the sensor's unflipped Bayer order,
#   so a sensor whose flip shifts it came out magenta or blue; the ImgU now
#   gets the order after the flips.
# Any x86_64 Linux with rootless podman (a fedora:43 container; on the
# Surface Go itself it works too, just slowly).
#   ./build-libcamera.sh
# Undo: rm -rf work/libcamera out/libcamera-rpms; podman rmi registry.fedoraproject.org/fedora:43
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
case "$PWD" in *[[:space:]]*) echo "the repository path must not contain spaces"; exit 1;; esac
TOP=$PWD
W=$TOP/work/libcamera
mkdir -p $W
rm -f "$W"/*.patch
cp patches/libcamera/*.patch $W/

cat >$W/build.sh <<'EOF'
#!/bin/bash
set -ex -o pipefail
cd /work
TOP=/work/rpmbuild
dnf -y -q install rpm-build dnf5-plugins </dev/null
[ -f libcamera-0.5.2-5.fc43.src.rpm ] || dnf -q download --srpm libcamera-0.5.2-5.fc43
rm -rf $TOP; mkdir -p $TOP
rpm -i --define "_topdir $TOP" libcamera-0.5.2-5.fc43.src.rpm
cp 0100-*.patch 0101-*.patch 0102-*.patch 0103-*.patch $TOP/SOURCES/
SPEC=$TOP/SPECS/libcamera.spec
sed -i \
  -e "/^Patch16:/a\\
\\
# IPU3: no abort (std::clamp lo > hi) for small 16:9 sizes;\\
# flicker-free exposure times (50 Hz); Surface Go 3 cameras mirrored;\\
# ImgU input in the Bayer order after the sensor's flips\\
Patch100: 0100-ipu3-imgu-skip-IF-heights-below-the-max-crop.patch\\
Patch101: 0101-ipu3-agc-flicker-free-exposure-50Hz.patch\\
Patch102: 0102-sensor-surface-go-3-cameras-mirrored.patch\\
Patch103: 0103-ipu3-imgu-input-bayer-order-after-flips.patch" \
  -e 's/^Release: 5%{?dist}$/Release: 5.5.ipu3%{?dist}/' \
  -e '/^%changelog$/a\
* Sun Oct 18 2026 Petr Karnakov <pkarnakov@gmail.com> - 0.5.2-5.5.ipu3\
- ipu3: skip IF heights below the max crop (std::clamp abort in WirePlumber)\
- ipu3: AGC exposure times in whole 10 ms periods (50 Hz flicker)\
- sensor: Surface Go 3 cameras (ov5693, ov8865) mounted mirrored\
- ipu3: ImgU input in the Bayer order after the sensor flips\
' $SPEC
grep -nE "^(Release|Patch16|Patch10[0-3]):" $SPEC
# the spec must have taken the patches and the new release
[ "$(grep -cE '^(Patch10[0-3]:|Release: 5\.5\.ipu3)' $SPEC)" = 5 ]
dnf -y -q builddep $SPEC </dev/null
rpmbuild -bb --nocheck --define "_topdir $TOP" $SPEC 2>&1 | grep -vE '^\[[0-9]+/[0-9]+\] |^(Compiling|Linking|\+ )'
rm -rf /work/RPMS; cp -a $TOP/RPMS/x86_64 /work/RPMS
EOF
chmod +x $W/build.sh
podman run --rm -v $W:/work:Z registry.fedoraproject.org/fedora:43 /work/build.sh
rm -rf out/libcamera-rpms; mkdir -p out
cp -a $W/RPMS out/libcamera-rpms
ls -l out/libcamera-rpms
