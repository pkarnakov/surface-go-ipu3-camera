#!/usr/bin/env python3
# On the Surface Go 3 (as root): an 8-bit GREY 640x480 IR camera on a
# v4l2loopback device, for face login (Howdy) or anything else that reads a
# plain V4L2 camera. libcamera ignores the ov7251 (mono, and its IR emitter
# has no driver), so this streams it raw through the CIO2 (v4l2-ctl), unpacks
# the IPU3 10-bit format and writes the frames to the loopback device. The
# emitter is the TPS68470 PMIC's WLED output 2 in flash mode, fired by the
# sensor's strobe on every frame; the exposure (and then the sensor gain)
# follows the picture's brightness. On exit the emitter goes off and the PMIC
# and sensor registers, the controls and the media link are put back (the
# pad formats stay set; libcamera sets its own).
#
# Started by surface-ir.service (Type=notify: ready after the first frame);
# exits when nobody has had the loopback device open for --idle seconds.
#   surface-ir.py [--idle S] [--current-ma MA]
#   surface-ir.py --test FRAMES [--out FILE.pgm]   # no loopback; prints AE
# Needs v4l-utils (media-ctl, v4l2-ctl), python3-numpy and, without --test,
# v4l2loopback loaded with card_label="Surface IR" exclusive_caps=1.
# Undo: it changes nothing lasting; `sudo make uninstall` removes the install.
import argparse
import ctypes
import fcntl
import glob
import os
import re
import select
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import time

import numpy as np

W, H, BPL = 640, 480, 832           # ip3y: 25 pixels in 32 bytes per line
FRAME = BPL * H
LOOPBACK_LABEL = 'Surface IR'

# Known boards (DMI product_name): the PMIC's address and revision, and the
# WLED output the emitter is on (the other one is unconnected and trips the
# boost's overvoltage flag, so it is disabled).
MODELS = {
    'Surface Go 3': {'pmic_addr': 0x4d, 'pmic_revid': 0x21, 'led': 2},
}

# TPS68470 (TI SLVSCJ1B)
GSTAT, WLEDMAXF, WLEDTO, WLEDC1, WLEDC2, WLEDCTL, REVID = 0x01, 0x2f, 0x30, 0x34, 0x35, 0x36, 0xff
PMIC_SAVED = (0x28, 0x2d, WLEDMAXF, WLEDTO, WLEDC1, WLEDC2, WLEDCTL)
WLED_EN, WLED_DISLED1, WLED_DISLED2 = 0x04, 0x08, 0x10   # MODE 0: flash
WLEDTO_852MS = 0x07
MA_PER_CODE = 32.5
MAX_CODE = 16                       # 520 mA, the most tested

# ov7251 (16-bit register addresses)
PAD_OEN, STROBE_MASK, STROBE_SPAN = 0x3005, 0x3b81, 0x3b8c   # span: 4 bytes, BE, lines
PAD_STROBE = 0x08
SPAN_MARGIN = 20                    # the pulse ends with the exposure; start it earlier
EXPOSURE_CAP = 400                  # hard limit: pulse <= 420 lines = 8.1 ms of a 33 ms frame
LINE_US = 19.33                     # (640 + 288 hblank) / 48 MHz
FRAME_TIMEOUT = 1.0                 # s without a frame: give up (the strobe may still fire)
LOCK = '/run/surface-ir.lock'
POKE = '/run/surface-ir.poke'       # touched by pam-start: counts as a reader for --idle

V4L2_CID_EXPOSURE, V4L2_CID_GAIN = 0x00980911, 0x00980913
VIDIOC_G_CTRL, VIDIOC_S_CTRL, VIDIOC_QUERYCTRL, VIDIOC_S_FMT = 0xc008561b, 0xc008561c, 0xc0445624, 0xc0d05605
V4L2_BUF_TYPE_VIDEO_OUTPUT, V4L2_FIELD_NONE = 2, 1
V4L2_PIX_FMT_GREY = 0x59455247


def log(*a):
    print(*a, file=sys.stderr, flush=True)


def run(*cmd):
    return subprocess.run(cmd, check=True, capture_output=True, text=True).stdout


class I2C:
    """Register access through /dev/i2c-N with I2C_RDWR, which works next to
    the kernel driver bound to the address."""
    I2C_RDWR, I2C_M_RD = 0x0707, 0x0001

    class Msg(ctypes.Structure):
        _fields_ = [('addr', ctypes.c_uint16), ('flags', ctypes.c_uint16),
                    ('len', ctypes.c_uint16), ('buf', ctypes.POINTER(ctypes.c_uint8))]

    class Data(ctypes.Structure):
        _fields_ = [('msgs', ctypes.c_void_p), ('nmsgs', ctypes.c_uint32)]

    def __init__(self, bus, addr, reg16):
        self.fd = os.open(f'/dev/i2c-{bus}', os.O_RDWR)
        self.addr, self.reg16 = addr, reg16

    def _reg(self, reg):
        return [reg >> 8, reg & 255] if self.reg16 else [reg]

    def _xfer(self, *msgs):
        bufs = [(ctypes.c_uint8 * len(b))(*b) for _, b in msgs]
        arr = (self.Msg * len(msgs))(*[self.Msg(self.addr, f, len(b), ctypes.cast(buf, ctypes.POINTER(ctypes.c_uint8)))
                                       for (f, b), buf in zip(msgs, bufs)])
        fcntl.ioctl(self.fd, self.I2C_RDWR, self.Data(ctypes.addressof(arr), len(msgs)))
        return bufs

    def read(self, reg, n=1):
        return list(self._xfer((0, self._reg(reg)), (self.I2C_M_RD, [0] * n))[1])

    def write(self, reg, *vals):
        for i, v in enumerate(vals):    # one register per message: proven on both chips
            self._xfer((0, self._reg(reg + i) + [v]))


class Subdev:
    def __init__(self, path):
        self.fd = os.open(path, os.O_RDWR)

    def range(self, cid):
        b = bytearray(struct.pack('II32siiiiI8x', cid, 0, b'', 0, 0, 0, 0, 0))
        fcntl.ioctl(self.fd, VIDIOC_QUERYCTRL, b)
        return struct.unpack_from('ii', b, 40)

    def get(self, cid):
        b = bytearray(struct.pack('Ii', cid, 0))
        fcntl.ioctl(self.fd, VIDIOC_G_CTRL, b)
        return struct.unpack('Ii', b)[1]

    def set(self, cid, v):
        fcntl.ioctl(self.fd, VIDIOC_S_CTRL, bytearray(struct.pack('Ii', cid, v)))


def by_name(pattern, name):
    for f in sorted(glob.glob(f'/sys/class/video4linux/{pattern}/name')):
        if open(f).read().strip() == name:
            return '/dev/' + f.split('/')[-2]
    return None


def find_devices():
    for md in sorted(glob.glob('/dev/media*')):
        graph = run('media-ctl', '-d', md, '-p')
        m = re.search(r'^- entity \d+: (ov7251 (\d+)-([0-9a-f]{4})) ', graph, re.M)
        if m:
            break
    else:
        sys.exit('no ov7251 in any media graph')
    sensor = m.group(1)
    block = graph[m.end():].split('\n- entity')[0]
    link = re.search(r'-> "(ipu3-csi2 (\d+))":0 \[([^\]]*)\]', block)
    if not link:
        sys.exit(f'no link from {sensor} to a CSI-2 receiver')
    pmic = glob.glob('/sys/bus/i2c/devices/i2c-INT3472:*/tps68470-gpio')
    if len(pmic) != 1:
        sys.exit('no TPS68470 (INT3472 with tps68470-gpio)')
    d = dict(media=md, sensor=sensor, sbus=int(m.group(2)), saddr=int(m.group(3), 16),
             csi=link.group(1), link_enabled='ENABLED' in link.group(3),
             video=by_name('video*', f'ipu3-cio2 {link.group(2)}'),
             subdev=by_name('v4l-subdev*', sensor),
             pbus=int(os.path.basename(os.path.realpath(os.path.dirname(pmic[0]) + '/..')).removeprefix('i2c-')))
    if not d['video'] or not d['subdev']:
        sys.exit(f'video or subdev node not found: {d}')
    return d


def unpacker():
    i = np.arange(25) * 10
    b, s = i // 8, (i % 8).astype(np.uint16)

    def unpack(raw):                # -> HxW uint16, 0..1023
        blk = np.frombuffer(raw, np.uint8).reshape(H, BPL // 32, 32)
        v = (blk[:, :, b].astype(np.uint16) | blk[:, :, b + 1].astype(np.uint16) << 8) >> s & 1023
        return v.reshape(H, -1)[:, :W]
    return unpack


def readers(path):
    """PIDs other than ours with the device open."""
    me, found = os.getpid(), set()
    for fd in glob.glob('/proc/[0-9]*/fd/*'):
        try:
            if os.readlink(fd) == path:
                pid = int(fd.split('/')[2])
                if pid != me:
                    found.add(pid)
        except OSError:
            pass
    return found


def sd_notify(msg):
    addr = os.environ.get('NOTIFY_SOCKET')
    if addr:
        with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as s:
            s.connect('\0' + addr[1:] if addr[0] == '@' else addr)
            s.send(msg.encode())


class Exposure:
    """Brightness control: the 95th percentile of the picture towards
    `target`, through one level in exposure lines at 1x gain: exposure up to
    `exp_cap` first (it is also the emitter's pulse), then sensor gain."""

    def __init__(self, sub, sensor, exp_cap, gain_cap, target):
        self.sub, self.sensor, self.target = sub, sensor, target
        emin, emax = sub.range(V4L2_CID_EXPOSURE)
        self.gmin, gmax = sub.range(V4L2_CID_GAIN)    # gmin is 1x
        self.emin, self.ecap = emin, min(exp_cap, emax)
        self.gcap = min(gain_cap * self.gmin, gmax)
        self.level, self.exp, self.gain, self.hold = 200.0, None, None, 0

    def set_span(self, old, new):
        # Only the low two bytes change (span <= 420; the high ones are 0).
        # Low byte first when growing, high first when shrinking: the value
        # in between is never above the larger of old and new.
        hi, lo = (STROBE_SPAN + 2, new >> 8), (STROBE_SPAN + 3, new & 255)
        for r, v in ((lo, hi) if new > old else (hi, lo)):
            self.sensor.write(r, v)

    def apply(self):
        e = int(max(self.emin, min(self.level, self.ecap)))
        g = int(max(self.gmin, min(self.gmin * self.level / e, self.gcap)))
        if e != self.exp:
            if self.exp is None:
                self.sensor.write(STROBE_SPAN, 0, 0, 0, 0)
            old = (self.exp or -SPAN_MARGIN) + SPAN_MARGIN
            if self.exp is None or e > self.exp:   # keep span >= exposure
                self.set_span(old, e + SPAN_MARGIN)
                self.sub.set(V4L2_CID_EXPOSURE, e)
            else:
                self.sub.set(V4L2_CID_EXPOSURE, e)
                self.set_span(old, e + SPAN_MARGIN)
        if g != self.gain:
            self.sub.set(V4L2_CID_GAIN, g)
        self.exp, self.gain = e, g

    def update(self, v):
        # The frames lag the settings by ~6 (sensor plus queued buffers): after
        # a change, wait two updates, and step only part of the way.
        p = max(float(np.percentile(v[::8, ::8], 95)), 8.0)
        if self.hold:
            self.hold -= 1
            return p
        r = min(max(self.target / p, 0.5), 2.0) ** 0.5
        top = self.ecap * self.gcap / self.gmin
        level = min(max(self.level * r, self.emin), top)
        if abs(level / self.level - 1) > 0.03:
            self.level, self.hold = level, 2
            self.apply()
        return p


def main():
    ap = argparse.ArgumentParser(description='Surface Go IR camera to v4l2loopback')
    ap.add_argument('--idle', type=float, default=10, help='exit after S seconds without readers (0: never)')
    ap.add_argument('--current-ma', type=float, default=520, help=f'emitter current, {MA_PER_CODE} mA steps, max 520')
    ap.add_argument('--exposure-max', type=int, default=EXPOSURE_CAP,
                    help=f'exposure (= pulse) cap in lines of {LINE_US} us, at most {EXPOSURE_CAP}')
    ap.add_argument('--gain-max', type=float, default=8, help='sensor gain cap (x)')
    ap.add_argument('--target', type=float, default=600, help='95th percentile target, of 1023')
    ap.add_argument('--test', type=int, metavar='FRAMES', help='no loopback: run FRAMES frames, print the AE')
    ap.add_argument('--out', default='ir-test.pgm', help='--test: last frame as PGM')
    a = ap.parse_args()

    product = open('/sys/class/dmi/id/product_name').read().strip()
    model = MODELS.get(product)
    if not model:
        sys.exit(f'unknown model {product!r} (known: {", ".join(MODELS)})')
    code = round(a.current_ma / MA_PER_CODE)
    if not 1 <= code <= MAX_CODE:
        sys.exit(f'--current-ma: {MA_PER_CODE}..{MAX_CODE * MA_PER_CODE}')
    if not 1 <= a.exposure_max <= EXPOSURE_CAP:
        sys.exit(f'--exposure-max: 1..{EXPOSURE_CAP}')
    lock = open(LOCK, 'w')
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        sys.exit('already running')

    d = find_devices()
    log(f'{product}: {d["sensor"]} via {d["csi"]} {d["video"]} {d["subdev"]}, PMIC i2c-{d["pbus"]}, '
        f'{code * MA_PER_CODE} mA')
    pmic = I2C(d['pbus'], model['pmic_addr'], False)
    if pmic.read(REVID)[0] != model['pmic_revid']:
        sys.exit('TPS68470 revision mismatch')
    sensor = I2C(d['sbus'], d['saddr'], True)
    sub = Subdev(d['subdev'])

    out = None
    if a.test is None:
        lb = by_name('video*', LOOPBACK_LABEL)
        if not lb:
            sys.exit(f'no v4l2loopback device "{LOOPBACK_LABEL}" (modprobe v4l2loopback, see 99-surface-ir.conf)')
        out = os.open(lb, os.O_RDWR)
        fcntl.ioctl(out, VIDIOC_S_FMT, bytearray(struct.pack('I4x12I152x', V4L2_BUF_TYPE_VIDEO_OUTPUT, W, H,
                    V4L2_PIX_FMT_GREY, V4L2_FIELD_NONE, W, W * H, *[0] * 6)))
        log(f'output {lb}')

    for sig in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, lambda *_: sys.exit(0))
    pmic_saved = {r: pmic.read(r)[0] for r in PMIC_SAVED}
    pmic_saved[WLEDCTL] = 0         # off, whatever a killed earlier run left
    ctrl_saved = {c: sub.get(c) for c in (V4L2_CID_EXPOSURE, V4L2_CID_GAIN)}
    sensor_saved, stream = None, None
    link = f'"{d["sensor"]}":0->"{d["csi"]}":0'
    try:
        if not d['link_enabled']:
            run('media-ctl', '-d', d['media'], '-l', f'{link}[1]')
        for pad in (f'"{d["sensor"]}":0', f'"{d["csi"]}":0', f'"{d["csi"]}":1'):
            run('media-ctl', '-d', d['media'], '-V', f'{pad}[fmt:Y10_1X10/{W}x{H}]')
        run('v4l2-ctl', '-d', d['video'], f'--set-fmt-video=width={W},height={H},pixelformat=ip3y')
        # own session: a Ctrl-C must not stop the stream before the sensor is restored;
        # PDEATHSIG: it ends with us all the same
        libc = ctypes.CDLL(None, use_errno=True)
        errs = tempfile.TemporaryFile()
        stream = subprocess.Popen(['v4l2-ctl', '-d', d['video'], '--stream-mmap=4', '--stream-to=-'],
                                  stdout=subprocess.PIPE, stderr=errs, bufsize=0,
                                  start_new_session=True, preexec_fn=lambda: libc.prctl(1, signal.SIGTERM))
        raw = bytearray(FRAME)
        view = memoryview(raw)

        def frame():
            n = 0
            while n < FRAME:
                if not select.select([stream.stdout], [], [], FRAME_TIMEOUT)[0]:
                    sys.exit(f'no frame for {FRAME_TIMEOUT:g} s')
                k = stream.stdout.readinto(view[n:])
                if not k:
                    errs.seek(0)
                    sys.exit(f'v4l2-ctl stopped (exit {stream.wait()}): '
                             + errs.read()[-500:].decode(errors='replace').strip())
                n += k
            return raw

        frame()                     # streaming: the sensor is powered and programmed
        sensor_saved = {PAD_OEN: sensor.read(PAD_OEN), STROBE_MASK: sensor.read(STROBE_MASK),
                        STROBE_SPAN: sensor.read(STROBE_SPAN, 4)}
        ae = Exposure(sub, sensor, a.exposure_max, a.gain_max, a.target)
        ae.apply()
        sensor.write(STROBE_MASK, 0xff)                 # strobe on every frame, not 0xa5's 4 of 8
        sensor.write(PAD_OEN, sensor_saved[PAD_OEN][0] | PAD_STROBE)
        # flash mode, level trigger by the strobe; WLEDTO and WLEDMAXF only with the boost off
        led = (WLED_DISLED1, WLEDC2) if model['led'] == 2 else (WLED_DISLED2, WLEDC1)
        pmic.write(WLEDCTL, 0)
        pmic.write(WLEDTO, WLEDTO_852MS)
        pmic.write(WLEDMAXF, code)
        pmic.write(WLEDC1, 0)
        pmic.write(WLEDC2, 0)
        pmic.write(led[1], code)
        pmic.write(WLEDCTL, led[0])
        pmic.write(WLEDCTL, led[0] | WLED_EN)

        unpack = unpacker()
        lb_path = out is not None and os.readlink(f'/proc/self/fd/{out}')
        n, t0, ready, last_reader, checked = 0, time.monotonic(), False, time.monotonic(), 0.0
        while a.test is None or n < a.test:
            v = unpack(frame())
            n += 1
            p = ae.update(v) if n % 3 == 0 else None
            if a.test is not None:
                if p is not None and n % 15 == 0:
                    log(f'frame {n:4} mean {v.mean():6.1f} p95 {p:6.1f} exposure {ae.exp:4} gain {ae.gain}')
                continue
            buf = memoryview((v >> 2).astype(np.uint8).tobytes())
            while buf:
                buf = buf[os.write(out, buf):]
            if not ready:
                sd_notify('READY=1')
                ready = True
            if n % 10 == 0:
                sd_notify('WATCHDOG=1')
            now = time.monotonic()
            if a.idle and now - checked >= 1:
                checked = now
                try:
                    poked = time.time() - os.stat(POKE).st_mtime < a.idle
                except OSError:
                    poked = False
                if poked or readers(lb_path):
                    last_reader = now
                elif now - last_reader > a.idle:
                    log(f'no readers for {a.idle:g} s, {n} frames in {now - t0:.0f} s')
                    break
        if a.test is not None:
            with open(a.out, 'wb') as f:
                f.write(b'P5 %d %d 1023\n' % (W, H) + v.astype('>u2').tobytes())
            log(f'{n} frames in {time.monotonic() - t0:.1f} s; last frame in {a.out}')
    finally:
        # nothing may interrupt this: the emitter goes off first
        for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
            signal.signal(sig, signal.SIG_IGN)
        for step in ([lambda: pmic.write(WLEDCTL, 0), lambda: sd_notify('STOPPING=1')]
                     + [lambda r=r: pmic.write(r, pmic_saved[r]) for r in PMIC_SAVED]
                     + [lambda: pmic.write(GSTAT, 0xfe)]                     # W1C the flags
                     + ([lambda r=r, v=v: sensor.write(r, *v) for r, v in sensor_saved.items()]
                        if sensor_saved else [])                             # while it still streams
                     + [lambda c=c, v=v: sub.set(c, v) for c, v in ctrl_saved.items()]):
            try:
                step()
            except OSError as e:
                log(f'restore: {e}')
        if stream:
            stream.terminate()
            stream.wait()
        if not d['link_enabled']:
            subprocess.run(['media-ctl', '-d', d['media'], '-l', f'{link}[0]'])


if __name__ == '__main__':
    main()
