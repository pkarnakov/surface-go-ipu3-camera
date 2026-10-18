#!/bin/bash
# On the Surface Go: a 1280x720 frame of the front camera with libcamera's
# IPA and one with Intel's (after 90 frames, AE/AWB settled), side by side at
# half size in ./frames/compare.png (left: libcamera, right: Intel), and
# the last fps line of each. Stop apps using the camera first.
#   test/compare.sh
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")/.."
F=$PWD/frames
rm -rf $F; mkdir -p $F
for ipa in libcamera intel; do
  if [ $ipa = intel ]; then export LIBCAMERA_IPA_MODULE_PATH=~/.local/lib/libcamera-ipu3-intel; fi
  # the number changes: with Intel's IPA the back camera is gone
  CAM=$(cam -l 2>/dev/null | grep -m1 CAMF | cut -d: -f1)
  mkdir -p $F/$ipa
  rc=0; timeout -k 3 30 cam -c "$CAM" --capture=90 \
    --stream width=1280,height=720,pixelformat=NV12 --file="$F/$ipa/f-#.nv12" \
    >$F/$ipa.out 2>&1 </dev/null || rc=$?
  echo "$ipa: rc=$rc (134 = abort, 139 = crash, 124 = hang)"
  grep -E "Using tuning|ERROR|FATAL|Assert" $F/$ipa.out | grep -v ov7251 | sed 's/\x1b\[[0-9;]*m//g' | sort | uniq -c | head -10 || true
  grep -E "fps\)" $F/$ipa.out | tail -1 || true
  last=$(ls $F/$ipa/*.nv12 | sort -V | tail -1); mv "$last" $F/$ipa.nv12; rm -rf $F/$ipa
done
python3 - $F <<'EOF'
# NV12 -> RGB at half size, side by side, as PNG (no numpy needed)
import sys, zlib, struct
d = sys.argv[1]; w, h = 1280, 720
def rgb(f):
    b = open(f, "rb").read()
    rows = []
    for y in range(0, h, 2):
        row = bytearray()
        uvrow = w * h + (y // 2) * w
        for x in range(0, w, 2):
            Y = (b[y * w + x] - 16) * 1.164
            u = b[uvrow + x] - 128; v = b[uvrow + x + 1] - 128
            for c in (Y + 1.596 * v, Y - 0.392 * u - 0.813 * v, Y + 2.017 * u):
                row.append(0 if c < 0 else 255 if c > 255 else int(c))
        rows.append(row)
    return rows
a, b = rgb(f"{d}/libcamera.nv12"), rgb(f"{d}/intel.nv12")
raw = b"".join(b"\0" + ra + rb for ra, rb in zip(a, b))
def chunk(t, x): return struct.pack(">I", len(x)) + t + x + struct.pack(">I", zlib.crc32(t + x))
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h // 2, 8, 2, 0, 0, 0)) \
      + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b"")
open(f"{d}/compare.png", "wb").write(png); print(f"{d}/compare.png")
EOF
