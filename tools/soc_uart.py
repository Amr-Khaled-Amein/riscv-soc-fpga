"""
talk to the soc on the board (soc/src/host_link.v) over the usb uart

    python soc_uart.py COM4 prog.elf                 # load, run, print what it prints
    python soc_uart.py COM4 --act                    # all compliance tests in tests/act4/elfs
    python soc_uart.py COM4 --fft                    # fft benchmark, results checked vs fft_model
    python soc_uart.py COM4 --ping
    python soc_uart.py COM4 ../build/sw/leds.elf --detach    # led demo, keeps running
    python soc_uart.py --list

1 Mbaud, 8N1. the loader writes / reads one byte at a time and the cpu sits in
reset until 'G'.
"""

import argparse
import glob
import os
import struct
import sys
import time

import elf

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, ".."))
BAUD = 1_000_000
CLK_HZ = 27_000_000
CHUNK = 4096


class Board:
    def __init__(self, port, baud=BAUD):
        import serial
        self.s = serial.Serial(port, baud, timeout=2)
        time.sleep(0.05)
        self.s.reset_input_buffer()

    def read(self, n):
        d = self.s.read(n)
        if len(d) != n:
            raise IOError(f"timeout: wanted {n} bytes, got {len(d)}")
        return d

    def ping(self):
        # if a program is still running (limit 0) the first byte stops it, so try a few times
        for _ in range(3):
            self.s.write(b"P")
            time.sleep(0.2)
            d = self.s.read(self.s.in_waiting)
            if d.endswith(b"ok"):
                return True
            self.s.reset_input_buffer()
        return False

    def write(self, addr, data):
        for i in range(0, len(data), CHUNK):
            part = data[i:i + CHUNK]
            self.s.write(b"W" + struct.pack(">II", addr + i, len(part)) + part)
            ack = self.read(2)
            x = 0
            for b in part:
                x ^= b
            if ack != bytes([ord("w"), x]):
                raise IOError(f"write at {addr + i:08x}: bad ack {ack.hex()}")

    def readmem(self, addr, n):
        out = bytearray()
        for i in range(0, n, CHUNK):
            k = min(CHUNK, n - i)
            self.s.write(b"R" + struct.pack(">II", addr + i, k))
            if self.read(1) != b"r":
                raise IOError("bad read reply")
            d = self.read(k)
            x = 0
            for b in d:
                x ^= b
            if self.read(1)[0] != x:
                raise IOError(f"read at {addr + i:08x}: checksum")
            out += d
        return bytes(out)

    def run(self, pc, limit_s=10.0, echo=False):
        """start at pc, collect the uart output until the end frame. -> (why, code, clocks, output)"""
        limit = min(int(limit_s * CLK_HZ), 0xFFFFFFFF)
        self.s.write(b"G" + struct.pack(">II", pc, limit))
        out = bytearray()
        t_end = time.time() + limit_s + 3
        while time.time() < t_end:
            d = self.s.read(self.s.in_waiting or 1)
            if not d:
                continue
            out += d
            k = out.find(b"\xff\xffE")
            if k >= 0 and len(out) >= k + 12:
                why, code, clocks = struct.unpack(">BII", out[k + 3:k + 12])
                if echo:
                    sys.stdout.write(out[:k].decode("latin1"))
                return why, code, clocks, bytes(out[:k])
        raise IOError("no end frame from the board")

    def load_elf(self, path, verify=False):
        segs, syms = elf.load(path)
        for a, data in segs:
            self.write(a, data)
            if verify and self.readmem(a, len(data)) != data:
                raise IOError(f"read back of {a:08x} doesn't match")
        return syms


# ---------------------------------------------------------------- modes

def run_act(b, verbose=False):
    files = sorted(glob.glob(os.path.join(ROOT, "tests", "act4", "elfs", "*", "*.elf")))
    npass = 0
    t0 = time.time()
    rows = []
    for f in files:
        syms = b.load_elf(f)
        why, code, clocks, out = b.run(syms["_entry"], limit_s=5)
        name = os.path.basename(f)[:-4]
        ok = why == 1 and code == 1 and b"TEST PASSED" in out
        npass += ok
        rows.append((name, ok, clocks))
        print(f"  {name:28s} {'PASS' if ok else 'FAIL'}  {clocks:8d} clocks")
        if not ok or verbose:
            print("    " + out.decode("latin1").strip().replace("\n", "\n    "))
    print(f"{npass}/{len(files)} passed on the board ({time.time() - t0:.0f} s)")
    return npass == len(files), rows


def run_random(b, n, seed=1):
    """random programs (no timer reads / interrupts), exit code has to match rv_sim"""
    import gen_random
    import rv_sim
    import simrun
    bad = 0
    t0 = time.time()
    for i in range(n):
        s = 9000 + seed * 1000 + i
        code = 0x80000000 if i % 2 else 0
        data = 0x80100000 if i % 4 >= 2 else 0x8000
        segs, _ = simrun.image_from_asm(gen_random.make(s, 300, data=data, timing=False), True, code)
        h = rv_sim.Hart()
        for a, d in segs:
            h.load_image(d, a)
            b.write(a, d)
        h.pc = code
        rv_sim.run(h, 1_000_000)
        why, got, clocks, out = b.run(code, limit_s=2)
        if why != 1 or got != h.io.exit:
            bad += 1
            print(f"  seed {s}: board {got:08x} model {h.io.exit:08x}")
    print(f"{n - bad}/{n} random programs: same exit code on the board as in the model ({time.time() - t0:.0f} s)")
    return bad == 0


def run_fft(b, path):
    import fft_model
    syms = b.load_elf(path)
    why, code, clocks, out = b.run(syms["_entry"], limit_s=10, echo=True)
    n = struct.unpack("<I", b.readmem(syms["res_count"], 4))[0]
    size = 6 * 512 + 16             # one result_t
    raw = b.readmem(syms["res"], n * size)
    errs = 0
    rows = []
    for i in range(n):
        r = raw[i * size:(i + 1) * size]
        v = struct.unpack("<1536h", r[:3072])
        in_re, in_im, sw_re, sw_im, hw_re, hw_im = (list(v[k * 256:(k + 1) * 256]) for k in range(6))
        swc, hwc, fftc, flags = struct.unpack("<4I", r[3072:])
        m_re, m_im, nsat = fft_model.fft_fixed(in_re, in_im)
        exact = (hw_re == m_re and hw_im == m_im and bool(flags & 2) == (nsat > 0))
        errs += not exact
        snr = fft_model.snr_db(hw_re, hw_im, in_re, in_im)
        rows.append({"sw": swc, "hw": hwc, "core": fftc, "exact": exact, "snr": snr, "clip": bool(flags & 2)})
        print(f"  signal {i}: board vs python model {'bit exact' if exact else 'DIFFERENT'}, "
              f"snr vs numpy {snr:.1f} dB{', clipped' if flags & 2 else ''}")
    print(f"exit {code}, {'all' if not errs else 'NOT all'} {n} signals match the model")
    return errs == 0 and code == 0, rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("port", nargs="?")
    ap.add_argument("elf", nargs="?")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--ping", action="store_true")
    ap.add_argument("--act", action="store_true")
    ap.add_argument("--fft", action="store_true")
    ap.add_argument("--random", type=int, default=0, help="run this many random programs")
    ap.add_argument("--verify", action="store_true", help="read memory back after loading")
    ap.add_argument("--limit", type=float, default=10.0, help="seconds before the board gives up")
    ap.add_argument("--detach", action="store_true", help="start it with no limit and don't wait (leds.elf)")
    a = ap.parse_args()

    if a.list:
        from serial.tools import list_ports
        for p in list_ports.comports():
            print(p.device, p.description)
        return
    if not a.port:
        ap.error("need a port")
    b = Board(a.port)
    if not b.ping():
        print("no answer to ping")
        sys.exit(1)
    if a.ping:
        print("ok")
        return
    if a.act:
        ok, _ = run_act(b)
        sys.exit(0 if ok else 1)
    if a.random:
        sys.exit(0 if run_random(b, a.random) else 1)
    if a.fft:
        ok, _ = run_fft(b, a.elf or os.path.join(ROOT, "build", "sw", "fft_bench.elf"))
        sys.exit(0 if ok else 1)
    syms = b.load_elf(a.elf, a.verify)
    if a.detach:
        b.s.write(b"G" + struct.pack(">II", syms["_entry"], 0))
        time.sleep(0.3)
        sys.stdout.write(b.s.read(b.s.in_waiting).decode("latin1"))
        print("(left running, the next command stops it)")
        return
    why, code, clocks, out = b.run(syms["_entry"], a.limit, echo=True)
    print(f"\n[{'exit ' + str(code) if why == 1 else 'stopped after the limit'}, {clocks} clocks = "
          f"{clocks / CLK_HZ * 1000:.2f} ms]")


if __name__ == "__main__":
    main()
