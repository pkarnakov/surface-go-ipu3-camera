# Surface Go 3 cameras on Linux with Intel's IPU3 3A

The Surface Go 3's cameras sit behind Intel's IPU3. libcamera supports it,
but its own image processing (IPA) only does exposure and white balance;
noise reduction and sharpening stay at fixed defaults, and there is no
tuning for the sensors. The result is soft, noisy, with a color cast
across the frame.

This repository runs **Intel's own 3A** instead: the IPU3 IPA that wraps
Intel's ChromeOS libraries (auto exposure, auto white balance, noise
reduction, sharpening, lens shading), driven by the **cameras' tuning from
Microsoft's Windows driver**. The front camera's picture comes out neutral
and noticeably sharper, at the same ~29 fps (1280x720) or ~57 fps
(640x360). The back camera gets brighter and cleaner too, but only at full
resolution (see Limitations).

One frame each, same scene under a desk lamp (click for full size):

| | libcamera's IPA | Intel's 3A |
|---|---|---|
| **Front** (ov5693, 1280x720) | <img width="360px" alt="front-libcamera" src="https://github.com/user-attachments/assets/53b178ec-b37d-4add-bde8-43f75e7e34d2" /> | <img width="360px" alt="front-intel" src="https://github.com/user-attachments/assets/b8b478df-91dc-4254-9a08-7d1f84f10f0d" /> |
| **Back** (ov8865, 3200x2432) | <img width="360px" alt="back-libcamera" src="https://github.com/user-attachments/assets/6b672e3c-1224-4972-9f63-d2b348b12ba2" /> | <img width="360px" alt="back-intel" src="https://github.com/user-attachments/assets/44009123-57f7-4d77-bbc7-5fc8835608e3" /> |

Tested on a Surface Go 3 with Fedora 43 (KDE), kernel 7.2 (stock Fedora),
libcamera 0.5.2, PipeWire/WirePlumber and Chromium.
Questions and reports: [linux-surface discussion
#2308](https://github.com/linux-surface/linux-surface/discussions/2308).

## What's here

| | |
|---|---|
| [`fetch-blobs.sh`](fetch-blobs.sh) | Downloads Microsoft's Surface Go 3 driver package and a ChromeOS recovery image, extracts the ov5693 and ov8865 tunings and Intel's libraries into `./blobs` (fixed up, see below). Nothing proprietary is in this repository. |
| [`build-ipa.sh`](build-ipa.sh) | Builds the IPA module in a fedora:43 container (podman) into `./out/ipa`, then runs an offline smoke test. |
| [`install-ipa.sh`](install-ipa.sh) | On the Surface Go: installs it for your user in `~/.local/lib/libcamera-ipu3-intel` and points WirePlumber at it. `--uninstall` undoes it. |
| [`build-libcamera.sh`](build-libcamera.sh), [`install-libcamera.sh`](install-libcamera.sh) | Fedora's libcamera 0.5.2 rebuilt with four fixes (below), installed and version-locked. |
| [`patches/ipu3-ipa/`](patches/ipu3-ipa/) | [camera/ipu3-ipa](https://gitlab.freedesktop.org/camera/ipu3-ipa) (4ff2368) ported to libcamera 0.5, plus the ov5693 and ov8865. |
| [`patches/libcamera/`](patches/libcamera/) | `0100`: no abort for 640x360 and similar sizes ([libcamera#366](https://gitlab.freedesktop.org/camera/libcamera/-/work_items/366)). `0101`: 50 Hz anti-flicker for libcamera's own IPA. `0102`: both cameras' pictures the right way round (they read out mirrored). `0103`: the ImgU gets the Bayer order after the sensor's flips (the ov5693's flip shifts it). |
| [`test/compare.sh`](test/compare.sh) | One frame with each IPA, side by side in `frames/front/compare.png` (`back`: the back camera). |
| [`test/preview.sh`](test/preview.sh) | Live preview in qcam (`front`/`back`, `intel`/`libcamera`). |
| [`test/camtest.html`](test/camtest.html) | Browser page: what apps get through PipeWire (cameras, exact sizes, fps). |

## Steps

Building needs any x86_64 Linux with rootless podman (the Surface Go
itself works, slowly), plus curl, unzip, sfdisk, debugfs (e2fsprogs),
python3 with venv, gcc and make for the fetch. Downloads are 2.5 GB; the
fetch needs ~10 GB of free disk at its peak, and 5 GB of it stays in
`./work` as a cache:

```bash
./fetch-blobs.sh
./build-libcamera.sh
./build-ipa.sh
```

Then, on the Surface Go (copy the directory over if you built elsewhere):

```bash
./install-libcamera.sh   # sudo: dnf install + versionlock
./install-ipa.sh         # user-level, restarts WirePlumber
test/compare.sh          # optional: frames/front/compare.png
```

> [!IMPORTANT]
> **Chromium (and Chrome) see no camera until you enable
> `chrome://flags/#enable-webrtc-pipewire-camera`** and restart the browser:
> apps reach the camera only through PipeWire, and Chromium uses V4L2 by
> default (the IPU3's `/dev/video*` nodes are raw Bayer, useless to it).

**Undo:** `./install-ipa.sh --uninstall` goes back to libcamera's own IPA.
For libcamera itself: `sudo dnf versionlock delete 'libcamera*'`, then
`sudo dnf distro-sync 'libcamera*'`, then `systemctl --user restart wireplumber`.
While the lock is in place, Fedora updates that need a newer libcamera are
held back too. Build output and caches: `rm -rf work blobs out`.

## Limitations

- **Back camera at full resolution only** (3200x2432, ~15 fps): at any
  other size the ov8865 driver (kernel 7.2) delivers one frame and stalls,
  whichever IPA runs, so apps asking for a smaller size hang. The IR
  sensor (ov7251) is not supported by libcamera.
- **Front camera fixed-focus:** the ov5693 module has no focus motor (the
  back camera's autofocus works).
- **Pinned to libcamera 0.5.2** (Fedora 43's `0.5.2-5.fc43`, from the
  updates repository: once Fedora ships a newer build, the build scripts
  can't download it any more). Then the version in the scripts has to
  move; for a different upstream release the IPA port has to be redone,
  since the IPA interface changes between libcamera releases.
- **50 Hz mains only:** flicker reduction is fixed to 50 Hz (Intel's AE in
  the ipu3-ipa patch, and 0101 for libcamera's own IPA). Under 60 Hz
  lights, change `ia_aiq_ae_flicker_reduction_50hz` to `_60hz` in the
  ipu3-ipa patch and `kFlickerPeriod` from `10ms` to `8333us` in 0101.
- **Some fine grain** on flat surfaces; noise reduction is as tuned for
  Windows.

## How it works, and what had to be fixed

- **Tuning.** The Windows driver ships a tuning per sensor and model,
  named by the camera's ACPI ID: `OV5693_YHCU_SKY.cpf` (front) and
  `OV8865_YHCT_SKY.cpf` (back) for the Go 2/3, `MSHW0070`, `MSHW0120`,
  `MSHW0140`/`MSHW0150` (and others) for the Pro 4, Pro 5/6 and Book 2.
  Each is a 32-byte `CPFF` header around an `AIQB`, the format Intel's
  library reads. Their black level (~16500 on the 16-bit scale) does not
  match what the sensor gives under Linux.
  Intel's ISP config then subtracts twice what libcamera does, which hits
  the weak blue channel hardest and turns the picture yellow-green.
  [`fetch-blobs.sh`](fetch-blobs.sh) sets the level to 4096, the value that came out
  neutral (1024 to 8192 tried), and recomputes the AIQB checksum (u32 sum
  of the file with the field zeroed).
- **Libraries.** `libia_*` and `libSkyCamAICKBL` come from the recovery
  image of soraka (HP Chromebook x2, also IPU3), ChromeOS 16700.66.0, with
  the libc++ they were built with. They use `DT_RELR` relocations without
  the `GLIBC_ABI_DT_RELR` version need that glibc insists on.
  [`fetch-blobs.sh`](fetch-blobs.sh) adds it with LIEF.
- **The IPA.** `camera/ipu3-ipa` dates from 2022. The patch:
  - renames for libcamera 0.5's interface (`computeParams`, `processStats`,
    `paramsComputed`);
  - registers the module under the pipeline name `ipu3`; with the old
    `PipelineHandlerIPU3`, libcamera loads the module but silently uses
    its own;
  - adds the ov5693 and ov8865 entries, with each sensor's gain code at
    1x for the AE's gain limit;
  - sends the autofocus lens position with the lens's controls (it went
    with the sensor's and was dropped, so the back camera stayed out of
    focus);
  - looks for the tuning next to the module;
  - keeps AE within the sensor's exposure and gain range, with 50 Hz
    flicker reduction.

  The module is linked with `DT_RPATH` `$ORIGIN/lib`, since `RUNPATH` does
  not reach the Intel libraries' own dependencies. libcamera runs unsigned
  IPA modules in a separate process, which also contains a crash of the
  closed libraries.
- **Selection.** `LIBCAMERA_IPA_MODULE_PATH` (set for WirePlumber by a
  systemd drop-in, [`wireplumber/50-ipu3-intel.conf`](wireplumber/50-ipu3-intel.conf)) is searched before the system's IPA directory; the
  first module matching the pipeline wins.

## Legal

The scripts and the ipu3-ipa patch are Apache-2.0 ([`LICENSE`](LICENSE)), like
ipu3-ipa itself. The patches in [`patches/libcamera/`](patches/libcamera/)
change libcamera files and are LGPL-2.1-or-later, like libcamera.
The tuning files and Intel's libraries are proprietary. They are not part
of this repository: [`fetch-blobs.sh`](fetch-blobs.sh) downloads them from Microsoft's and
Google's public servers on your machine, for use on your own device.
