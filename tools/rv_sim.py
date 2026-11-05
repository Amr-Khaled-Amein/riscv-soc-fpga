"""
instruction level model of the cpu (rv32i + zicsr + m-mode traps), one instruction
at a time, no pipeline. this is the golden model for the rtl.

two ways to use it:
  - on its own: run a program, peripherals are faked well enough for the c programs
        python rv_sim.py prog.elf
  - lockstep with the rtl: check_trace() walks the commit trace from the testbench
    and steps the model for every line. reads from io (timer etc) and interrupts
    come from the trace, everything else has to match exactly.
"""

import argparse
import sys

import elf

MASK = 0xFFFFFFFF
RAM_BYTES = 1 << 16
SD_BASE = 0x80000000
SD_BYTES = 1 << 23
IO_BASE = 0x10000000

UART, TIMER, FFT, SYS = (IO_BASE + 0x1000 * i for i in range(4))


def sx(v, bits):
    v &= (1 << bits) - 1
    return v - (1 << bits) if v >> (bits - 1) else v


def s32(v):
    return sx(v, 32)


class Trap(Exception):
    def __init__(self, cause, tval=0):
        super().__init__(cause)
        self.cause = cause
        self.tval = tval & MASK


class FakeIO:
    """peripherals for running without the rtl"""

    def __init__(self):
        self.out = bytearray()
        self.exit = None
        self.led = 0
        self.scratch = 0
        self.mtime = 0
        self.mtimecmp = MASK | (MASK << 32)
        self.fft_in = [(0, 0)] * 256
        self.fft_out = [(0, 0)] * 256
        self.fft_stat = 0
        self.fft_wait = 0           # status reads that still say busy

    def load(self, addr):
        a = addr & ~3
        if a == UART:
            return 0
        if a == UART + 4:
            return 0x80000000
        if a == UART + 8:
            return 4
        if a == TIMER:
            return self.mtime & MASK
        if a == TIMER + 4:
            return self.mtime >> 32
        if a == TIMER + 8:
            return self.mtimecmp & MASK
        if a == TIMER + 12:
            return self.mtimecmp >> 32
        if a == FFT + 4:
            if self.fft_wait:
                self.fft_wait -= 1
                return 1
            return self.fft_stat
        if a == FFT + 8:
            return 1029
        if FFT + 0x400 <= a < FFT + 0x800:
            re, im = self.fft_out[(a - FFT - 0x400) >> 2]
            return ((re & 0xFFFF) << 16) | (im & 0xFFFF)
        if a == SYS:
            return self.led
        if a == SYS + 8:
            return 27000000
        if a == SYS + 12:
            return self.scratch
        return 0

    def store(self, addr, data, strb):
        a = addr & ~3
        if a == UART and strb & 1:
            self.out.append(data & 0xFF)
        elif a == SYS:
            if strb & 1:
                self.led = data & 0x1F
        elif a == SYS + 4:
            self.exit = data
        elif a == SYS + 12:
            m = sum(0xFF << (8 * i) for i in range(4) if strb >> i & 1)
            self.scratch = (self.scratch & ~m) | (data & m)
        elif a == TIMER + 8:
            self.mtimecmp = (self.mtimecmp & ~MASK) | data
        elif a == TIMER + 12:
            self.mtimecmp = (self.mtimecmp & MASK) | (data << 32)
        elif a == FFT and data & 1:
            import fft_model
            re = [sx(v[0], 16) for v in self.fft_in]
            im = [sx(v[1], 16) for v in self.fft_in]
            o_re, o_im, nsat = fft_model.fft_fixed(re, im)
            self.fft_out = list(zip(o_re, o_im))
            self.fft_stat = 2 | (4 if nsat else 0)
            self.fft_wait = 3
        elif FFT + 0x400 <= a < FFT + 0x800:
            self.fft_in[(a - FFT - 0x400) >> 2] = (data >> 16, data & 0xFFFF)


class Hart:
    def __init__(self, ram_bytes=RAM_BYTES, io=None):
        self.ram_bytes = ram_bytes
        self.mem = bytearray(ram_bytes)
        self.sd = bytearray(SD_BYTES)
        self.x = [0] * 32
        self.pc = 0
        self.io = io or FakeIO()
        # csrs
        self.mie_b = self.mpie_b = self.mtie = 0
        self.mtvec = self.mscratch = self.mepc = self.mcause = self.mtval = 0
        self.mcycle = self.minstret = 0
        self.inh_cy = self.inh_ir = 0
        self.irq_line = 0
        self.io_word = None       # in lockstep mode the next io load returns this

    # ---------------- memory ----------------
    def in_ram(self, a):
        return 0 <= a < self.ram_bytes

    @staticmethod
    def in_sd(a):
        return SD_BASE <= a < SD_BASE + SD_BYTES

    @staticmethod
    def in_io(a):
        return (a >> 14) == 0x4000

    def buf(self, a):
        """(bytearray, offset) for an address in ram or sdram"""
        if self.in_ram(a):
            return self.mem, a
        if self.in_sd(a):
            return self.sd, a - SD_BASE
        return None, 0

    def load_image(self, image, base=0):
        m, off = self.buf(base)
        m[off:off + len(image)] = image

    def rd32(self, a):
        m, off = self.buf(a)
        return int.from_bytes(m[off:off + 4], "little")

    # ---------------- csrs ----------------
    def csr_read(self, n):
        """value, or None if there's no such csr"""
        if n == 0x300:
            return (3 << 11) | (self.mpie_b << 7) | (self.mie_b << 3)
        if n == 0x301:
            return 0x40000100
        if n == 0x304:
            return self.mtie << 7
        if n == 0x344:
            return self.irq_line << 7
        if n == 0x305:
            return self.mtvec
        if n == 0x340:
            return self.mscratch
        if n == 0x341:
            return self.mepc
        if n == 0x342:
            return self.mcause
        if n == 0x343:
            return self.mtval
        if n == 0x320:
            return (self.inh_ir << 2) | self.inh_cy
        if n in (0x310, 0xF11, 0xF12, 0xF13, 0xF14, 0xF15):
            return 0
        if n in (0xB00, 0xC00):
            return self.mcycle & MASK
        if n in (0xB80, 0xC80):
            return self.mcycle >> 32
        if n in (0xB02, 0xC02):
            return self.minstret & MASK
        if n in (0xB82, 0xC82):
            return self.minstret >> 32
        if 0xB03 <= n <= 0xB1F or 0xB83 <= n <= 0xB9F or 0x323 <= n <= 0x33F:
            return 0
        return None

    def csr_write(self, n, v):
        if n == 0x300:
            self.mie_b, self.mpie_b = (v >> 3) & 1, (v >> 7) & 1
        elif n == 0x304:
            self.mtie = (v >> 7) & 1
        elif n == 0x305:
            self.mtvec = v & ~3
        elif n == 0x340:
            self.mscratch = v
        elif n == 0x341:
            self.mepc = v & ~3
        elif n == 0x342:
            self.mcause = v
        elif n == 0x343:
            self.mtval = v
        elif n == 0x320:
            self.inh_cy, self.inh_ir = v & 1, (v >> 2) & 1
        elif n == 0xB00:
            self.mcycle = (self.mcycle & ~MASK) | v
        elif n == 0xB80:
            self.mcycle = (self.mcycle & MASK) | (v << 32)
        elif n == 0xB02:
            self.minstret = (self.minstret & ~MASK) | v
        elif n == 0xB82:
            self.minstret = (self.minstret & MASK) | (v << 32)

    def take_trap(self, cause, tval):
        self.mepc = self.pc & ~3
        self.mcause = cause
        self.mtval = tval
        self.mpie_b = self.mie_b
        self.mie_b = 0
        self.pc = self.mtvec

    def irq_pending(self):
        return bool(self.mie_b and self.mtie and self.irq_line)

    # ---------------- one instruction ----------------
    def step(self):
        """
        run one instruction. returns a dict:
          kind 'C' (it retired) or 'T' (trapped), pc, instr, rd/val if it wrote a
          register, st=(addr, data, strb) for a store, io=addr for an io load
        """
        pc = self.pc
        rec = {"kind": "C", "pc": pc, "instr": 0, "rd": 0, "val": 0}
        try:
            if not self.in_ram(pc) and not self.in_sd(pc):
                raise Trap(1, pc)
            ins = self.rd32(pc)
            rec["instr"] = ins
            self.execute(ins, rec)
        except Trap as t:
            rec["kind"] = "T"
            rec["cause"] = t.cause
            rec["rd"] = rec["val"] = 0
            rec.pop("st", None)
            rec.pop("io", None)
            self.take_trap(t.cause, t.tval)
            return rec
        if not self.inh_ir and not rec.get("wrote_instret"):
            self.minstret = (self.minstret + 1) & ((1 << 64) - 1)
        rec.pop("wrote_instret", None)
        return rec

    def interrupt(self):
        """take the timer interrupt in front of the next instruction"""
        rec = {"kind": "T", "pc": self.pc, "instr": self.rd32(self.pc) if self.buf(self.pc)[0] else 0,
               "rd": 0, "val": 0, "cause": 0x80000007}
        self.take_trap(0x80000007, 0)
        return rec

    def execute(self, ins, rec):
        x = self.x
        pc = self.pc
        op = ins & 0x7F
        rd = (ins >> 7) & 31
        f3 = (ins >> 12) & 7
        rs1 = (ins >> 15) & 31
        rs2 = (ins >> 20) & 31
        f7 = ins >> 25
        a, b = x[rs1], x[rs2]
        imm_i = sx(ins >> 20, 12)
        nxt = (pc + 4) & MASK
        res = None

        def jump(t):
            t &= MASK
            if t & 2:
                raise Trap(0, t)
            return t

        if op == 0x37:
            res = ins & 0xFFFFF000
        elif op == 0x17:
            res = (pc + (ins & 0xFFFFF000)) & MASK
        elif op == 0x6F:
            imm = sx(((ins >> 31) << 20) | (((ins >> 12) & 0xFF) << 12) | (((ins >> 20) & 1) << 11) |
                     (((ins >> 21) & 0x3FF) << 1), 21)
            nxt = jump(pc + imm)
            res = (pc + 4) & MASK
        elif op == 0x67:
            if f3:
                raise Trap(2, ins)
            nxt = jump((a + imm_i) & ~1)
            res = (pc + 4) & MASK
        elif op == 0x63:
            imm = sx(((ins >> 31) << 12) | (((ins >> 7) & 1) << 11) | (((ins >> 25) & 0x3F) << 5) |
                     (((ins >> 8) & 0xF) << 1), 13)
            if f3 in (2, 3):
                raise Trap(2, ins)
            take = {0: a == b, 1: a != b, 4: s32(a) < s32(b), 5: s32(a) >= s32(b),
                    6: a < b, 7: a >= b}[f3]
            if take:
                nxt = jump(pc + imm)
        elif op == 0x03:
            if f3 in (3, 6, 7):
                raise Trap(2, ins)
            addr = (a + imm_i) & MASK
            size = 1 << (f3 & 3)
            if addr & (size - 1):
                raise Trap(4, addr)
            if self.buf(addr)[0] is not None:
                word = self.rd32(addr & ~3)
                if self.in_sd(addr):
                    self.io_word = None         # sdram goes over axi too, but we know it
            elif self.in_io(addr):
                rec["io"] = addr
                if self.io_word is not None:
                    word, self.io_word = self.io_word, None
                else:
                    word = self.io.load(addr) & MASK
            else:
                raise Trap(5, addr)
            v = word >> (8 * (addr & 3))
            res = {0: sx(v, 8), 1: sx(v, 16), 2: v, 4: v & 0xFF, 5: v & 0xFFFF}[f3] & MASK
        elif op == 0x23:
            if f3 > 2:
                raise Trap(2, ins)
            imm = sx(((ins >> 25) << 5) | ((ins >> 7) & 31), 12)
            addr = (a + imm) & MASK
            size = 1 << f3
            if addr & (size - 1):
                raise Trap(6, addr)
            m, off = self.buf(addr)
            if m is None and not self.in_io(addr):
                raise Trap(7, addr)
            sh = 8 * (addr & 3)
            strb = ((1 << size) - 1) << (addr & 3)
            data = ((b & ((1 << (8 * size)) - 1)) << sh) & MASK
            rec["st"] = (addr, data, strb)
            if m is not None:
                for i in range(size):
                    m[off + i] = (b >> (8 * i)) & 0xFF
            else:
                self.io.store(addr, data, strb)
        elif op == 0x13:
            if f3 == 0:
                res = a + imm_i
            elif f3 == 2:
                res = int(s32(a) < imm_i)
            elif f3 == 3:
                res = int(a < (imm_i & MASK))
            elif f3 == 4:
                res = a ^ (imm_i & MASK)
            elif f3 == 6:
                res = a | (imm_i & MASK)
            elif f3 == 7:
                res = a & (imm_i & MASK)
            elif f3 == 1:
                if f7:
                    raise Trap(2, ins)
                res = a << rs2
            else:
                if f7 not in (0, 0x20):
                    raise Trap(2, ins)
                res = (s32(a) >> rs2) if f7 else (a >> rs2)
            res &= MASK
        elif op == 0x33:
            if f7 == 0x20 and f3 not in (0, 5) or f7 not in (0, 0x20):
                raise Trap(2, ins)
            sh = b & 31
            if f3 == 0:
                res = a - b if f7 else a + b
            elif f3 == 1:
                res = a << sh
            elif f3 == 2:
                res = int(s32(a) < s32(b))
            elif f3 == 3:
                res = int(a < b)
            elif f3 == 4:
                res = a ^ b
            elif f3 == 5:
                res = (s32(a) >> sh) if f7 else (a >> sh)
            elif f3 == 6:
                res = a | b
            else:
                res = a & b
            res &= MASK
        elif op == 0x0F:
            if f3 > 1:
                raise Trap(2, ins)
        elif op == 0x73:
            if f3 == 0:
                if ins == 0x00000073:
                    raise Trap(11, 0)
                if ins == 0x00100073:
                    raise Trap(3, pc)
                if ins == 0x30200073:
                    nxt = self.mepc
                    self.mie_b, self.mpie_b = self.mpie_b, 1
                elif ins != 0x10500073:
                    raise Trap(2, ins)
            elif f3 == 4:
                raise Trap(2, ins)
            else:
                n = ins >> 20
                old = self.csr_read(n)
                wr = (f3 & 3) == 1 or rs1 != 0
                if old is None or (wr and (n >> 10) == 3):
                    raise Trap(2, ins)
                src = rs1 if f3 & 4 else a
                if wr:
                    new = {1: src, 2: old | src, 3: old & ~src & MASK}[f3 & 3]
                    self.csr_write(n, new)
                    if n in (0xB02, 0xB82):
                        rec["wrote_instret"] = True
                if n in (0xB00, 0xB80, 0xC00, 0xC80, 0x344):
                    rec["cycle_csr"] = True     # clock count / irq line, the model can't know these
                res = old
        else:
            raise Trap(2, ins)

        if res is not None and rd:
            x[rd] = res & MASK
            rec["rd"], rec["val"] = rd, x[rd]
        self.pc = nxt


# ---------------------------------------------------------------- lockstep

def parse_trace_line(line):
    p = line.split()
    if p[0] == "T":
        return {"kind": "T", "pc": int(p[1], 16), "instr": int(p[2], 16), "cause": int(p[3], 16),
                "rd": 0, "val": 0}
    r = {"kind": "C", "pc": int(p[1], 16), "instr": int(p[2], 16), "rd": int(p[3]), "val": int(p[4], 16)}
    i = 5
    while i < len(p):
        if p[i] == "S":
            r["st"] = (int(p[i + 1], 16), int(p[i + 2], 16), int(p[i + 3], 16))
            i += 4
        elif p[i] == "L":
            r["ioword"] = int(p[i + 1], 16)
            i += 2
        else:
            raise ValueError(f"bad trace line: {line}")
    return r


def fmt(r):
    if r["kind"] == "T":
        return f"pc {r['pc']:08x} {r['instr']:08x}  trap cause {r['cause']:x}"
    s = f"pc {r['pc']:08x} {r['instr']:08x}"
    if r.get("rd"):
        s += f"  x{r['rd']} = {r['val']:08x}"
    if "st" in r:
        a, d, m = r["st"]
        s += f"  store [{a:08x}] {d:08x} strb {m:x}"
    return s


def same(rtl, mod):
    if rtl["kind"] != mod["kind"] or rtl["pc"] != mod["pc"]:
        return False
    # on a fetch fault there is no instruction, the rtl shows whatever the ram gave
    fetch_fault = rtl["kind"] == "T" and rtl["cause"] == 1
    if rtl["instr"] != mod["instr"] and not fetch_fault:
        return False
    if rtl["kind"] == "T":
        return rtl["cause"] == mod["cause"]
    if rtl["rd"] != mod["rd"] or (rtl["rd"] and rtl["val"] != mod["val"] and not mod.get("cycle_csr")):
        return False
    if ("st" in rtl) != ("st" in mod):
        return False
    if "st" in rtl:
        a1, d1, m1 = rtl["st"]
        a2, d2, m2 = mod["st"]
        bm = sum(0xFF << (8 * i) for i in range(4) if m1 >> i & 1)
        if a1 != a2 or m1 != m2 or (d1 & bm) != (d2 & bm):
            return False
    return True


def check_trace(hart, lines, max_report=5):
    """
    step the model along an rtl commit trace. returns (n checked, list of errors)
    """
    errs = []
    n = 0
    recent = []
    for line in lines:
        if not line.strip():
            continue
        try:
            r = parse_trace_line(line)
        except ValueError:
            # x / z in the trace: the rtl went somewhere undefined
            errs.append(f"instruction {n + 1}: unknown values in the rtl trace: {line.strip()[:60]}")
            break
        if r["kind"] == "T" and r["cause"] == 0x80000007:
            hart.irq_line = 1
            m = hart.interrupt()
        else:
            # the rtl got this io word, give the model the same one
            hart.io_word = r.get("ioword")
            m = hart.step()
            if m.get("cycle_csr") and r["kind"] == "C" and r["rd"]:
                hart.x[r["rd"]] = r["val"]
        n += 1
        if not same(r, m):
            errs.append(f"instruction {n}:\n    rtl   {fmt(r)}\n    model {fmt(m)}")
            if recent:
                errs[-1] += "\n    before that:\n" + "\n".join("      " + fmt(q) for q in recent[-4:])
            if len(errs) >= max_report:
                break
            # resync so one bug doesn't hide the next
            hart.pc = r["pc"]
        recent.append(r)
    return n, errs


# ---------------------------------------------------------------- standalone

def run(hart, max_steps=10_000_000):
    """run until the exit register is written. returns number of instructions"""
    n = 0
    while hart.io.exit is None and n < max_steps:
        hart.io.mtime += 4
        hart.irq_line = int(hart.io.mtime >= hart.io.mtimecmp)
        if hart.irq_pending():
            hart.interrupt()
        else:
            hart.step()
        n += 1
    return n


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("prog", help=".elf or .hex (words from address 0)")
    ap.add_argument("--max", type=int, default=50_000_000)
    a = ap.parse_args()
    h = Hart()
    if a.prog.endswith(".elf"):
        segs, syms = elf.load(a.prog)
        for base, data in segs:
            h.load_image(data, base)
        h.pc = syms["_entry"]
    else:
        with open(a.prog) as f:
            words = [int(w, 16) for w in f.read().split()]
        h.load_image(b"".join(w.to_bytes(4, "little") for w in words))
    n = run(h, a.max)
    sys.stdout.write(h.io.out.decode("latin1"))
    print(f"\n[{n} instructions, exit {h.io.exit}]")


if __name__ == "__main__":
    main()
