#!/bin/bash
# Build Intel's IPU3 IPA for libcamera 0.5.2 into ./out/ipa (the module,
# lib/ with Intel's libraries, both tunings). The IPA is camera/ipu3-ipa
# (gitlab.freedesktop.org, 4ff2368, 2022; it wraps Intel's ChromeOS
# libraries) with patches/ipu3-ipa: ported to libcamera 0.5, ov5693 entry,
# AE kept within the sensor's limits, 50 Hz flicker reduction. Built in a
# fedora:43 container against Fedora's libcamera-devel 0.5.2, with the
# private headers it needs (libcamera/base/log.h, linux/intel-ipu3.h) from
# the source package. Then an offline smoke test in the same container:
# init/configure/start and 60 frames of synthetic statistics, black and grey.
# Needs ./blobs from fetch-blobs.sh. Any x86_64 Linux with rootless podman.
#   ./build-ipa.sh
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
TOP=$PWD
W=$TOP/work/ipa
[ -f blobs/lib/libSkyCamAICKBL.so ] || { echo "run ./fetch-blobs.sh first"; exit 1; }
mkdir -p $W
cp patches/ipu3-ipa/*.patch test/ipa_smoke.cpp $W/
rm -rf $W/blobs && cp -a blobs $W/blobs

cat >$W/build.sh <<'EOF'
#!/bin/bash
set -ex -o pipefail
cd /work
dnf -y -q install rpm-build dnf5-plugins patch meson gcc-c++ libatomic git-core \
  libcamera-devel-0.5.2-5.fc43 </dev/null
# private headers (libcamera/base/log.h, linux/intel-ipu3.h) from the source
[ -f libcamera-0.5.2-5.fc43.src.rpm ] || dnf -q download --srpm libcamera-0.5.2-5.fc43
rm -rf rpmbuild; mkdir rpmbuild
rpm -i --define "_topdir /work/rpmbuild" libcamera-0.5.2-5.fc43.src.rpm
rpmbuild -bp --nodeps --define "_topdir /work/rpmbuild" rpmbuild/SPECS/libcamera.spec >/dev/null 2>&1
INC=$(dirname "$(dirname "$(find /work/rpmbuild/BUILD -path '*/include/linux/intel-ipu3.h' | head -1)")")
ls $INC/libcamera/base/log.h
rm -rf ipu3-ipa
git clone -q https://gitlab.freedesktop.org/camera/ipu3-ipa.git
git -C ipu3-ipa checkout -q 4ff2368
git -C ipu3-ipa apply /work/0001-*.patch
cd ipu3-ipa
# the Intel libraries to link with (and their libc++, for the linker's checks)
export LIBRARY_PATH=/work/blobs/lib LD_LIBRARY_PATH=/work/blobs/lib
CXXFLAGS="$(rpm --eval '%{build_cxxflags}')" LDFLAGS="$(rpm --eval '%{build_ldflags}')" \
  meson setup build --buildtype=plain -Dwerror=false --prefix=/work/out --libdir=lib \
  -Dcpp_args="-I$INC" | tail -2
rc=0; ninja -C build >ninja.out 2>&1 || rc=$?
grep -vE '^\[[0-9]+/[0-9]+\] (Compiling|Linking)|^c\+\+ ' ninja.out | tail -40 || true
[ $rc = 0 ]
meson install -C build --no-rebuild | tail -2
M=/work/out/lib/libcamera/intel-ipu3-ipa.so
readelf -d $M | grep -E 'RPATH|RUNPATH|NEEDED'
# offline smoke test with Fedora's libcamera, the module laid out as
# installed (its RPATH finds lib/)
unset LD_LIBRARY_PATH
rm -rf /work/inst && mkdir -p /work/inst
cp $M /work/inst/ && cp -a /work/blobs/lib /work/inst/lib
cp /work/blobs/ov5693_MSHW0140.aiqb /work/inst/ov5693.aiqb
g++ -std=c++17 -O1 -DLIBCAMERA_BASE_PRIVATE -I$INC -I/usr/include/libcamera \
  /work/ipa_smoke.cpp -lcamera -lcamera-base -o /work/ipa_smoke
for v in 0 64; do
  STATFILL=$v /work/ipa_smoke /work/inst/intel-ipu3-ipa.so 60 >smoke.out 2>&1 || true
  sed 's/\x1b\[[0-9;]*m//g; s/^\[[0-9:.]*\] \[[0-9]*\] *//' smoke.out \
    | grep -vE 'INFO (AIQ|AIBD)|^IA AIQ' | sort | uniq -c | sort -rn | head -20
  grep -q '^after 60 frames' smoke.out
  # libcamera matches the module by the pipeline handler's name
  grep -q '^module: api 1 pipeline 1 ipu3 ' smoke.out
done
EOF
chmod +x $W/build.sh
podman run --rm -v $W:/work:Z registry.fedoraproject.org/fedora:43 /work/build.sh
rm -rf out/ipa; mkdir -p out/ipa
cp $W/out/lib/libcamera/intel-ipu3-ipa.so blobs/ov5693_MSHW01[45]0.aiqb out/ipa/
cp -a blobs/lib out/ipa/lib
ls -lR out/ipa
