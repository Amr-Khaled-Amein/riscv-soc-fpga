"""
whole design over the uart pins (sim/tb_top.sv): writes the host script, runs it,
and checks every byte that comes back

    python top_test.py

what it does: junk byte, a command that stops halfway (has to time out), ping,
write + read back in block ram and sdram, run a program from sdram that prints,
copies data from sdram to block ram and exits, read that back, then a program
that never exits and has to be stopped by the clock limit.
"""

import os
import random
import struct
import sys

import rv_asm
import simrun

PROG = """
    li   t0, 0x10000000
    li   t1, 'o'
    sw   t1, 0(t0)
    li   t1, 'k'
    sw   t1, 0(t0)
    la   a0, data
    li   a1, 0x100
    li   a2, 16
copy:
    lw   t2, 0(a0)
    sw   t2, 0(a1)
    addi a0, a0, 4
    addi a1, a1, 4
    addi a2, a2, -1
    bnez a2, copy
    li   t0, 0x10003004
    li   t1, 0x55
    sw   t1, 0(t0)
    j    .
data:
"""


def xor(b):
    x = 0
    for v in b:
        x ^= v
    return x


def run(src=simrun.SRC):
    d = simrun.build_dir("top")
    rnd = random.Random(5)
    words = [rnd.getrandbits(32) for _ in range(16)]
    mem, _ = rv_asm.assemble(".org 0x80000000\n" + PROG + "".join(f"    .word 0x{w:08x}\n" for w in words))
    prog = bytes(mem.get(0x80000000 + i, 0) for i in range(max(mem) + 1 - 0x80000000))
    blob = bytes(rnd.getrandbits(8) for _ in range(40))
    spin, _ = rv_asm.assemble("    j .\n")
    spin = rv_asm.to_bytes(spin)

    steps, expect = [], []          # expect: list of byte strings or ("end", why, code)

    def send(b):
        steps.append(f"S {len(b)} " + " ".join(f"{x:02x}" for x in b))

    def wait(n):
        steps.append(f"N {n}")

    def w_cmd(addr, data):
        send(b"W" + struct.pack(">II", addr, len(data)) + data)
        wait(2)
        expect.append(bytes([ord("w"), xor(data)]))

    def r_cmd(addr, data):
        send(b"R" + struct.pack(">II", addr, len(data)))
        wait(len(data) + 2)
        expect.append(b"r" + data + bytes([xor(data)]))

    send(b"\x00")                               # junk, ignored
    send(b"W\x00\x00\x00")                      # stops halfway
    steps.append("D 5000")                      # longer than TIMEOUT
    send(b"P")
    wait(2)
    expect.append(b"ok")
    w_cmd(0x200, blob)
    r_cmd(0x200, blob)
    w_cmd(0x80000000, prog)
    r_cmd(0x80000000, prog)
    send(b"G" + struct.pack(">II", 0x80000000, 100000))
    steps.append("E")
    expect.append(("end", b"ok", 1, 0x55))
    r_cmd(0x100, b"".join(struct.pack("<I", w) for w in words))
    w_cmd(0x0, spin)
    send(b"G" + struct.pack(">II", 0x0, 400))
    steps.append("E")
    expect.append(("end", b"", 2, 0))
    send(b"P")
    wait(2)
    expect.append(b"ok")

    with open(os.path.join(d, "host.txt"), "w") as f:
        f.write("\n".join(steps) + "\n")
    files = [os.path.join(src, f) for f in simrun.TOP_FILES] + [os.path.join(simrun.SIM, "tb_top.sv"),
                                                                 os.path.join(simrun.SIM, "sdram_model.sv")]
    simrun.sh(["iverilog", "-g2012", "-Wall", "-Wno-timescale", "-o", "top.vvp"] + files, d)
    out = simrun.sh(["vvp", "-n", "top.vvp"], d)
    errs = []
    if "DONE" not in out:
        errs += [l for l in out.splitlines() if "FAIL" in l or "SDRAM" in l][:5] or ["tb_top didn't finish"]
    with open(os.path.join(d, "uart.out")) as f:
        raw = f.read().split()
    if any("x" in v.lower() or "z" in v.lower() for v in raw):
        return errs + ["the fpga sent bytes with x / z in them"]
    got = bytes(int(v, 16) for v in raw)

    # walk through what came back
    p = 0
    for e in expect:
        if isinstance(e, tuple):
            _, text, why, code = e
            k = got.find(b"\xff\xffE", p)
            if k < 0 or len(got) < k + 12:
                errs.append("missing end frame")
                break
            w, c, clocks = struct.unpack(">BII", got[k + 3:k + 12])
            if got[p:k] != text or w != why or c != code:
                errs.append(f"run: printed {got[p:k]!r}, why {w}, code {c:#x}; want {text!r}, {why}, {code:#x}")
            p = k + 12
        else:
            if got[p:p + len(e)] != e:
                errs.append(f"reply {got[p:p + len(e)][:12].hex()}... want {e[:12].hex()}...")
            p += len(e)
    if p != len(got):
        errs.append(f"{len(got) - p} extra bytes at the end")
    return errs


if __name__ == "__main__":
    e = run()
    print("PASS" if not e else "FAIL\n  " + "\n  ".join(e))
    sys.exit(1 if e else 0)
