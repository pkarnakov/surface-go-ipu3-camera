# IR camera

The Surface Go 3's IR camera (ov7251, 640x480 mono, behind the front glass
next to the front camera) as a plain V4L2 camera, `/dev/video42` "Surface
IR", 8-bit GREY at 30 fps, with its IR emitter lit. For face login
(Howdy) or anything else that reads V4L2.

Nothing else drives it on Linux: libcamera skips mono sensors, and the
emitter hangs off the camera PMIC (TPS68470) with no LED driver in the
kernel. [`surface-ir.py`](surface-ir.py) does both from userspace:

- streams the sensor raw through the CIO2 (`media-ctl`, `v4l2-ctl`) and
  unpacks the IPU3 10-bit format;
- turns on the emitter: the PMIC's WLED output 2 (output 1 is
  unconnected) in flash mode, triggered by the sensor's strobe, which
  is set to fire on every frame;
- sets the exposure, which is also the emitter pulse (at most 420 lines,
  8.1 ms of a 33 ms frame, a hard limit), then the sensor gain, from the
  brightness;
- writes the frames to a v4l2loopback device;
- when it exits, turns the emitter off and puts the PMIC and sensor
  registers, the controls and the media link back (the pad formats stay
  set; libcamera sets its own). It also stops if no frame comes for 1 s,
  and systemd's watchdog stops it if it hangs.

Tested on a Surface Go 3 (`Surface_Go_3_2022`), Fedora 43, kernel 7.2. It
refuses to run on other models (DMI); the Go 2 is probably wired the same,
an entry in `MODELS` once tested.

## Register values

Taken from the TPS68470 datasheet (TI SLVSCJ1B) and by testing on the device.

| Chip | Register | Value | Meaning |
|---|---|---|---|
| TPS68470 (i2c, 0x4d) | WLEDTO 0x30 | 0x07 | flash timeout 852 ms |
| | WLEDMAXF 0x2f, WLEDC2 0x35 | 16 | 16 x 32.5 = 520 mA |
| | WLEDC1 0x34 | 0 | output 1 off |
| | WLEDCTL 0x36 | 0x08, then 0x0c | flash mode, DISLED1, level trigger; then EN |
| ov7251 | 0x3005 | bit 3 set | STROBE pad output |
| | 0x3b81 | 0xff | strobe frame mask (default 0xa5: 4 frames of 8) |
| | 0x3b8c..0x3b8f | exposure + 20 | strobe span in lines, big endian; it ends with the exposure |

The MAX registers and WLEDTO only take writes with WLEDCTL EN off.

## Install

```sh
sudo dnf install v4l-utils python3-numpy akmod-v4l2loopback   # RPM Fusion free
make check
sudo ./surface-ir.py --test 90      # 3 s without loopback: prints the exposure, writes ir-test.pgm
sudo make install                   # sudo make uninstall
sudo modprobe -r v4l2loopback       # if it was loaded without the options
sudo systemctl start surface-ir     # then e.g.: ffplay /dev/video42
```

The service stops itself about 10 s after the last reader closed the
device, or 10 s after starting if no one opens it. The
options in [`99-surface-ir.conf`](99-surface-ir.conf) (after the package's
`98-v4l2loopback.conf`, so they win) apply to every
v4l2loopback device, so they clash with another v4l2loopback setup (OBS);
merge them by hand there.

## Face login

Howdy reads `/dev/video42` (`device_path` in its config; the frames are
already gray). Start the feed before Howdy in the PAM service, for example
in `/etc/pam.d/sudo`:

```
auth optional pam_exec.so quiet seteuid /usr/local/libexec/surface-ir/pam-start
auth sufficient pam_howdy.so
```

`pam-start` waits for the first frame and always succeeds, so the password
still works when the feed doesn't. It needs root to start the service
(`seteuid`: sudo and su run PAM with the caller's real uid). A screen
locker that checks the password as the user (KDE's) can't get root that
way; it would need a polkit rule allowing
`org.freedesktop.systemd1.manage-units` for `surface-ir.service`. Not
tested with Howdy yet.
