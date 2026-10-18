# AGENTS.md

Intel's IPU3 3A (camera/ipu3-ipa plus Intel's closed ChromeOS libraries,
with the Surface Go 3 Windows tuning) for the Surface Go 3's cameras
(ov5693 front, ov8865 back) under libcamera 0.5.2 on Fedora 43. The [README](README.md) covers what it does
and why; this file covers how to work on it.

## Rules

- **Nothing proprietary in git**, not even temporarily: no `.aiqb`/`.cpf`,
  no Intel or ChromeOS libraries, no MSI or recovery image contents, no
  dumps of them (hex, base64, tables of their values). They are fetched by
  [`fetch-blobs.sh`](fetch-blobs.sh) into the ignored `blobs/` and `work/`. Generated output
  (`out/`, `frames/`, logs) and binaries of any kind stay out too.
- **Versions are pinned on purpose:** libcamera `0.5.2-5.fc43`, ipu3-ipa
  `4ff2368`, ChromeOS soraka 16700.66.0, the Surface Go 3 driver MSI
  26.080.320.0, Python `olefile==0.47 lief==1.0.0`. Changing one means
  re-testing on the device; the IPA interface changes between libcamera
  releases.
- **Scripts:** bash with `set -euo pipefail`. Each starts with a header
  saying what it does and why, where it runs (any Linux, or on the Surface
  Go), what it needs, and how to undo it. They cd to the repo and work
  relative to it, refuse a path with spaces, and quote paths they delete. No hostnames, personal paths or other machine-specific
  details.
- **Patches** are `git format-patch` output against the pinned upstream
  commit ([`patches/ipu3-ipa/`](patches/ipu3-ipa/)) or plain diffs against Fedora's source
  package ([`patches/libcamera/`](patches/libcamera/), applied as `Patch100`/`Patch101` in the
  spec). Regenerate them from a real tree; don't hand-edit hunks.
- Apache-2.0 (as ipu3-ipa): the files the ipu3-ipa patch touches are
  Apache-2.0 (meson.build CC0); keep it so. `patches/libcamera/` changes
  LGPL-2.1-or-later files and is LGPL like them.

## Testing

- [`fetch-blobs.sh`](fetch-blobs.sh) runs anywhere without root. Its inputs are pinned by
  sha256 and its output is deterministic: compare `sha256sum` of `blobs/`
  before and after a change.
- [`build-libcamera.sh`](build-libcamera.sh) and [`build-ipa.sh`](build-ipa.sh) need rootless podman (fedora:43).
  [`build-ipa.sh`](build-ipa.sh) fails unless the offline smoke test ([`test/ipa_smoke.cpp`](test/ipa_smoke.cpp))
  gets through 60 frames and reports the pipeline name `ipu3`.
- Picture quality only shows on the device: [`test/compare.sh`](test/compare.sh) (stop apps
  using the camera first), then look at `frames/compare.png`. Judge color
  on neutral surfaces (walls, gray clothes): measure mean U/V there instead
  of eyeballing.

## Facts that cost time to find

- libcamera matches an IPA module by `ipaModuleInfo.pipelineName` against
  the pipeline handler's registered name (`ipu3`). A mismatch is silent: the
  module loads, then the system IPA is used.
- `LIBCAMERA_IPA_MODULE_PATH` is searched before the system directory; the
  first matching module wins. WirePlumber gets it from the systemd drop-in;
  restart WirePlumber after changes. Unsigned modules run in
  `ipu3_ipa_proxy`, a separate process.
- `cam` numbers cameras by which ones initialized: look the front one up
  with `cam -l | grep CAMF` (back: `CAMR`) under the same environment as
  the capture, don't hardcode it.
- The tunings are per model, named by the camera's ACPI ID: Go 2/3 front
  `YHCU`, back `YHCT` (the linux-surface wiki's camera page lists them).
  The `MSHW*` files in the same MSI are other Surfaces'; the Book 2's
  `MSHW0140` looked almost the same on the Go 3.
- Gain codes differ per sensor: 1x is 16 on the ov5693 (1..127), 128 on
  the ov8865 (128..2048); the IPA's sensor table carries it.
- The ov8865 driver only streams at full resolution (3264x2448 asked,
  3200x2432 out); other sizes give one frame, then stall, with either IPA.
- `cam -F` takes its file name only as `--file=NAME`; `-F NAME` is a usage
  error (rc 1).
- AIQB: a makernote, header `AIQB`, u32 size at 4, checksum at 20 = u32 sum
  of the whole file with that field zeroed; records `{u32 size, u8 format,
  u8 key, u16 name_id}` from offset 24. A wrong checksum makes
  `ia_cmc_parser_init` fail ("Failed to initialise CMC Parser").
- The black level record is name_id 3. The AIC sets the ISP's obgrid to
  about level / 128. The Windows value (~16600) gives 128 and a yellow-green
  picture; 4096 (obgrid 32) is neutral. libcamera's own IPA uses obgrid 64.
- Intel's AWB gains are fine (BNR `wb_gains` are U3.13 with gain = 1 + x;
  gr = 0 means 1.0). For a color cast, check obgrid, CCM and shading
  before suspecting AWB.
- `DT_RUNPATH` does not apply to the Intel libraries' own dependencies;
  the module needs `DT_RPATH` (`-Wl,--disable-new-dtags`) with
  `$ORIGIN/lib`.
- Debug logging: `LIBCAMERA_LOG_LEVELS=IPAManager:0,IPAModule:0,IPAProxy:0,IPAIPU3:0,AIQ:0`
  (AIQ:0 prints the AE/AWB/PA results per frame).
- To inspect the ISP parameters without the device, run the module offline
  as [`test/ipa_smoke.cpp`](test/ipa_smoke.cpp) does: feed `processStats` synthetic AWB cells
  (Gr, R, B, Gb, sat, 3 bytes padding per 8-byte cell) and print fields of
  `ipu3_uapi_params` after `computeParams`.
