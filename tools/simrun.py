"""
helpers to run a program on the rtl (iverilog + sim/tb_soc.sv) and check it
"""

import os
import subprocess

import elf
import rv_asm
import rv_sim

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, ".."))
SRC = os.path.join(ROOT, "soc", "src")
SIM = os.path.join(ROOT, "sim")
BUILD = os.path.join(ROOT, "build")

SOC_FILES = ["soc.v", "rv_core.v", "rv_decode.v", "rv_alu.v", "rv_csr.v", "ram.v", "ram_lane.v",
             "axil_xbar.v", "axil_slave.v", "uart_axi.v", "timer_axi.v", "sys_axi.v", "fft_axi.v",
             "fft_core.v", "sample_ram.v", "twiddle_rom.v", "sdram_ctrl.v", "sdram_axi.v"]
TOP_FILES = SOC_FILES + ["top.v", "host_link.v", "uart_tx.v", "uart_rx.v"]
RAM_BYTES = 1 << 16
SD_BASE = 0x80000000
SD_BYTES = 1 << 23


def sh(cmd, cwd):
    r = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stdout)
        print(r.stderr)
        raise RuntimeError(f"command failed: {' '.join(cmd)}")
    return r.stdout + r.stderr


def build_dir(name):
    d = os.path.join(BUILD, name)
    os.makedirs(d, exist_ok=True)
    return d


def compile_soc(d, src=SRC):
    files = [os.path.join(src, f) for f in SOC_FILES] + [os.path.join(SIM, "tb_soc.sv"),
                                                          os.path.join(SIM, "sdram_model.sv")]
    sh(["iverilog", "-g2012", "-Wall", "-Wno-timescale", "-o", "soc.vvp"] + files, d)
    return os.path.join(d, "soc.vvp")


def image_from_asm(path_or_text, is_text=False, base=0):
    """-> ([(address, bytes)], symbols). the program is placed at base"""
    text = path_or_text if is_text else open(path_or_text).read()
    if base:
        text = f".org 0x{base:x}\n" + text
    mem, syms = rv_asm.assemble(text)
    # split into pieces where there's a big gap (code in one memory, data in another)
    segs, start, prev = [], None, None
    for a in sorted(mem):
        if start is None or a - prev > 4096:
            if start is not None:
                segs.append((start, bytes(mem.get(i, 0) for i in range(start, prev + 1))))
            start = a
        prev = a
    segs.append((start, bytes(mem.get(i, 0) for i in range(start, prev + 1))))
    return segs, syms


def image_from_elf(path):
    return elf.load(path)


def write_hex(path, segs, base, nbytes):
    """the part of the segments inside [base, base + nbytes) as a hex file of words"""
    img = bytearray()
    for a, data in segs:
        if base <= a < base + nbytes:
            off = a - base
            if off + len(data) > nbytes:
                raise ValueError(f"segment at {a:08x} ({len(data)} bytes) doesn't fit")
            if len(img) < off + len(data):
                img += bytes(off + len(data) - len(img))
            img[off:off + len(data)] = data
    img += bytes(-len(img) % 4)
    with open(path, "w") as f:
        for i in range(len(img) // 4):
            f.write(f"{int.from_bytes(img[4 * i:4 * i + 4], 'little'):08x}\n")
    return len(img)


def run(d, vvp, segs, pc=0, trace=True, max_cycles=2_000_000):
    """
    run a program (list of (address, bytes)) on the rtl in folder d. returns a dict
    with exit, cycles, instret, uart (bytes), regs, and the trace check if trace=True
    """
    for a, data in segs:
        if not (a + len(data) <= RAM_BYTES or SD_BASE <= a < SD_BASE + SD_BYTES):
            raise ValueError(f"segment at {a:08x} is outside ram and sdram")
    write_hex(os.path.join(d, "prog.hex"), segs, 0, RAM_BYTES)
    nsd = write_hex(os.path.join(d, "sd.hex"), segs, SD_BASE, SD_BYTES)
    for f in ("trace.txt", "result.txt", "uart.out"):
        p = os.path.join(d, f)
        if os.path.exists(p):
            os.remove(p)
    args = ["vvp", "-n", vvp, "+hex=prog.hex", f"+max={max_cycles}", f"+pc={pc:x}"]
    if nsd:
        args.append("+sdhex=sd.hex")
    if trace:
        args.append("+trace")
    sh(args, d)
    res = {"exit": None, "regs": {}}
    with open(os.path.join(d, "result.txt")) as f:
        for line in f:
            k, *v = line.split()
            if k == "exit":
                res["exit"] = int(v[0])
            elif k in ("cycles", "instret", "axi_errors", "sdram_errors"):
                res[k] = int(v[0])
            elif k.startswith("x"):
                res["regs"][int(k[1:])] = int(v[0], 16) if "x" not in v[0] else None
    with open(os.path.join(d, "uart.out"), "rb") as f:
        res["uart"] = f.read()
    if trace:
        h = rv_sim.Hart()
        for a, data in segs:
            h.load_image(data, a)
        h.pc = pc
        with open(os.path.join(d, "trace.txt")) as f:
            n, errs = rv_sim.check_trace(h, f)
        res["checked"], res["errors"] = n, errs
        res["model_uart"] = bytes(h.io.out)
        res["model_exit"] = h.io.exit
    return res


def ok(res):
    """the rtl finished, the trace matched, and the model agrees on exit code and output"""
    if res["exit"] is None or res.get("axi_errors") or res.get("sdram_errors"):
        return False
    if "errors" in res:
        return (not res["errors"] and res["checked"] > 0 and res["model_exit"] == res["exit"]
                and res["model_uart"] == res["uart"])
    return True
