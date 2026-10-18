#!/bin/bash
# Fetch the proprietary parts of Intel's IPU3 3A into ./blobs (never in git):
# - ov5693.aiqb, ov8865.aiqb: the front and back cameras' tuning from
#   Microsoft's Surface Go 3 driver package (OV5693_YHCU_SKY.cpf,
#   OV8865_YHCT_SKY.cpf: YHCU/YHCT are the Go 2/3's ACPI IDs; the package
#   also has the other IPU3 Surfaces' tunings, by their MSHW IDs). Each
#   .cpf is a 32-byte CPFF header around the AIQB that Intel's library
#   reads. Its black level (~16600 on the 16-bit scale) is not what the
#   sensor gives under Linux: the ISP then over-subtracts and the picture
#   turns yellow-green. It is set to 4096 (neutral; 1024..8192 tried) and the
#   AIQB checksum (u32 sum of the file, the field zeroed) recomputed.
# - lib/: Intel's IPU3 3A libraries (libia_*, libSkyCamAICKBL) and the libc++
#   they were built with, from the ChromeOS recovery image of soraka (HP
#   Chromebook x2, also IPU3). libSkyCamAICKBL and libc++ use DT_RELR
#   relocations without the GLIBC_ABI_DT_RELR version need that glibc
#   requires ("DT_RELR without GLIBC_ABI_DT_RELR dependency"); LIEF adds it.
# Any x86_64 Linux, no root: needs curl, unzip, sfdisk, debugfs (e2fsprogs),
# python3 (venv), gcc and make (cabextract is built here). Downloads 2.5 GB,
# ~10 GB of disk at the peak; ./work keeps the MSI (0.7 GB) and the image's
# root partition (4.3 GB), the unpacked recovery image (4.5 GB) is deleted
# once that is cut out.
# The MSI and the root partition are checked against pinned sha256 sums.
#   ./fetch-blobs.sh
# Undo: rm -rf work/blobs blobs
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
case "$PWD" in *[[:space:]]*) echo "the repository path must not contain spaces"; exit 1;; esac
# sfdisk and debugfs live in /sbin on some distributions
export PATH=$PATH:/usr/sbin:/sbin
for t in curl unzip sfdisk debugfs python3 gcc make; do
  command -v $t >/dev/null || { echo "missing: $t"; exit 1; }
done
TOP=$PWD
W=$TOP/work/blobs
MSI=SurfaceGo3_Win11_22631_26.080.320.0.msi
MSI_URL=https://download.microsoft.com/download/100ded78-f124-4076-ab44-4be7375925fa/$MSI
REC=chromeos_16700.66.0_soraka_recovery_lts-channel_SorakaMPKeys-v9.bin
REC_URL=https://dl.google.com/dl/edgedl/chromeos/recovery/$REC.zip
MSI_SHA256=41983621dd0568e69257124f02dd19c66408c91686ffda199a950638e5292703
ROOTA_SHA256=73d8d68fce2d27b2ec924a8f464555d73b82c66b29eb0646bceb4287239036b2
BLACK_LEVEL=4096
mkdir -p $W $TOP/blobs/lib
cd $W

# --- tools ---
[ -x venv/bin/python ] || python3 -m venv venv
venv/bin/pip install -q olefile==0.47 lief==1.0.0
if [ ! -x cabextract-1.11/cabextract ]; then
  curl -sSfL https://www.cabextract.org.uk/cabextract-1.11.tar.gz | tar xz
  (cd cabextract-1.11 && ./configure -q >/dev/null && make -s >/dev/null)
fi

# --- tuning from the Windows driver ---
if [ ! -f $MSI ]; then curl -sSfL -o $MSI.part "$MSI_URL" && mv $MSI.part $MSI; fi
echo "$MSI_SHA256  $MSI" | sha256sum -c --quiet || { echo "$MSI: wrong checksum, delete it and rerun"; exit 1; }
rm -rf msi && mkdir msi
venv/bin/python - $MSI msi <<'EOF'
# the MSI's cabinets, and its File table (file key -> long file name)
import olefile, struct, sys
msi, out = sys.argv[1], sys.argv[2]
o = olefile.OleFileIO(msi)
A = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz._"
def dec(name):
    s = ""
    for ch in name:
        c = ord(ch)
        if 0x3800 <= c < 0x4800: c -= 0x3800; s += A[c & 0x3f] + A[(c >> 6) & 0x3f]
        elif 0x4800 <= c < 0x4840: s += A[c - 0x4800]
        elif c == 0x4840: s += "!"
        else: s += ch
    return s
streams = {dec(e[0]): e for e in o.listdir()}
n = 0
for name, e in streams.items():
    if o.get_size(e[0]) > 100_000_000:
        open(f"{out}/{n}.cab", "wb").write(o.openstream(e).read()); n += 1
pool = o.openstream(streams["!_StringPool"]).read()
data = o.openstream(streams["!_StringData"]).read()
big = bool(struct.unpack_from("<HH", pool, 0)[1] & 0x8000)
strings, off, i = [""], 0, 4
while i < len(pool):
    ln, rc = struct.unpack_from("<HH", pool, i); i += 4
    if ln == 0 and rc: ln = struct.unpack_from("<I", pool, i)[0]; i += 4
    strings.append(data[off:off + ln].decode("utf-8", "replace")); off += ln
sz = 3 if big else 2
t = o.openstream(streams["!File"]).read()
widths = [sz, sz, sz, 4, sz, sz, 2, 2]
if len(t) % sum(widths): widths[-1] = 4
rows = len(t) // sum(widths)
cols, p = [], 0
for w in widths:
    cols.append([int.from_bytes(t[p + k * w:p + (k + 1) * w], "little") for k in range(rows)]); p += w * rows
with open(f"{out}/files.tsv", "w") as f:
    for k in range(rows):
        f.write(f"{strings[cols[0][k]]}\t{strings[cols[2][k]].split('|')[-1]}\n")
print(n, "cabinets,", rows, "files")
EOF
cabextract-1.11/cabextract -q -d msi/x msi/*.cab
rm -f "$TOP"/blobs/*.aiqb
for v in OV5693_YHCU OV8865_YHCT; do
  key=$(awk -F'\t' -v n="${v}_SKY.cpf" 'toupper($2) == toupper(n) {print $1}' msi/files.tsv)
  [ -n "$key" ] || { echo "not in the MSI: ${v}_SKY.cpf"; exit 1; }
  s=${v%%_*}
  venv/bin/python - msi/x/$key $TOP/blobs/${s,,}.aiqb $BLACK_LEVEL <<'EOF'
import struct, sys
b = open(sys.argv[1], "rb").read()
assert b[:4] == b"CPFF" and b[0x20:0x24] == b"AIQB", "not a CPF around an AIQB"
b = bytearray(b[0x20:0x20 + struct.unpack_from("<I", b, 0x24)[0]])
# black level LUTs (record name id 3, cmc_name_id_black_level) to a constant
val = int(sys.argv[3])
off = 24
while struct.unpack_from("<H", b, off + 6)[0] != 3:
    off += struct.unpack_from("<I", b, off)[0]
n = struct.unpack_from("<I", b, off + 8)[0]
old = struct.unpack_from("<4H", b, off + 20)
for k in range(n):
    struct.pack_into("<4H", b, off + 20 + 16 * k, val, val, val, val)
struct.pack_into("<I", b, 20, 0)
struct.pack_into("<I", b, 20, sum(struct.unpack_from(f"<{len(b) // 4}I", b)) & 0xffffffff)
open(sys.argv[2], "wb").write(b)
print(sys.argv[2], len(b), "bytes;", n, "black level LUTs", old, "->", val)
EOF
done
rm -rf msi

# --- Intel's libraries from ChromeOS ---
if [ ! -f rootA.img ]; then
  if [ ! -f $REC ]; then
    curl -sSfL -o rec.zip.part "$REC_URL"
    unzip -q -o rec.zip.part $REC -d rec.tmp && mv rec.tmp/$REC $REC && rm -r rec.zip.part rec.tmp
  fi
  # ROOT-A is partition 3
  read -r start size < <(sfdisk -J $REC | venv/bin/python -c '
import json, sys
p = json.load(sys.stdin)["partitiontable"]["partitions"][2]
print(p["start"], p["size"])')
  dd if=$REC of=rootA.img.part bs=512 skip=$start count=$size status=none
  mv rootA.img.part rootA.img
  rm $REC
fi
echo "$ROOTA_SHA256  rootA.img" | sha256sum -c --quiet || { echo "rootA.img: wrong checksum, delete it and rerun"; exit 1; }
debugfs -c -R 'cat /etc/lsb-release' rootA.img 2>/dev/null | grep -E 'RELEASE_(BOARD|VERSION)='
for l in libia_aiq libia_cmc_parser libia_coordinate libia_exc libia_log libia_mkn libia_nvm libSkyCamAICKBL; do
  debugfs -c -R "dump /usr/lib64/$l.so $TOP/blobs/lib/$l.so" rootA.img 2>/dev/null
done
debugfs -c -R "dump /usr/lib64/libc++.so.1.0 $TOP/blobs/lib/libc++.so.1" rootA.img 2>/dev/null
debugfs -c -R "dump /usr/lib64/libc++abi.so.1.0 $TOP/blobs/lib/libc++abi.so.1" rootA.img 2>/dev/null
# debugfs exits 0 even when a file is missing
for l in libia_aiq libia_cmc_parser libia_coordinate libia_exc libia_log libia_mkn libia_nvm libSkyCamAICKBL; do
  [ -s $TOP/blobs/lib/$l.so ] || { echo "missing in the image: $l.so"; exit 1; }
done
[ -s $TOP/blobs/lib/libc++.so.1 ] && [ -s $TOP/blobs/lib/libc++abi.so.1 ]
venv/bin/python - $TOP/blobs/lib <<'EOF'
# add the GLIBC_ABI_DT_RELR version need glibc wants with DT_RELR
import lief, sys, os
def elf_hash(s):
    h = 0
    for c in s.encode():
        h = ((h << 4) + c) & 0xffffffff
        g = h & 0xf0000000
        if g: h ^= g >> 24
        h &= ~g & 0xffffffff
    return h
for name in sorted(os.listdir(sys.argv[1])):
    path = f"{sys.argv[1]}/{name}"
    b = lief.ELF.parse(path)
    if not any(e.tag == lief.ELF.DynamicEntry.TAG.RELR for e in b.dynamic_entries):
        continue
    req = next(r for r in b.symbols_version_requirement if r.name == "libc.so.6")
    if any(a.name == "GLIBC_ABI_DT_RELR" for a in req.get_auxiliary_symbols()):
        continue
    a = lief.ELF.SymbolVersionAuxRequirement()
    a.name, a.hash = "GLIBC_ABI_DT_RELR", elf_hash("GLIBC_ABI_DT_RELR")
    a.other = 1 + max(x.other for r in b.symbols_version_requirement
                      for x in r.get_auxiliary_symbols())
    req.add_auxiliary_requirement(a)
    b.write(path)
    print("patched", name)
EOF
chmod 644 $TOP/blobs/lib/* $TOP/blobs/*.aiqb
cd $TOP/blobs && sha256sum *.aiqb lib/*
