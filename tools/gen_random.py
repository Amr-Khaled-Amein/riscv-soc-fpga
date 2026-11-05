"""
random test programs for the pipeline

each program is a pile of random blocks: alu ops on a few registers (so almost
everything depends on the instruction right before it), loads/stores, forward
branches, small loops, calls, csr ops, io accesses, self modifying code with
fence.i, and things that trap (ecall, ebreak, illegal, misaligned, bad address).
with --irq the timer interrupt fires every few hundred clocks on top.

the rtl trace is checked against rv_sim line by line, so a program doesn't need
to compute anything useful, it just has to be deterministic.

    python gen_random.py --seed 3 -o r3.s
"""

import argparse
import random

# x1..x12 are the random ones, the rest is used by the frame below
#   x20 scratch for blocks   x21 scratch   x24..x27 trap handler   x23 irq count
#   x28 timer base           x29 data base   x30 loop counter      x31 link for calls
WORK = [f"x{i}" for i in range(1, 13)]
DATA = 0x8000
TIMER = 0x10001000
SYS = 0x10003000

R = ["add", "sub", "sll", "slt", "sltu", "xor", "srl", "sra", "or", "and"]
I = ["addi", "slti", "sltiu", "xori", "ori", "andi"]
SH = ["slli", "srli", "srai"]
BR = ["beq", "bne", "blt", "bge", "bltu", "bgeu"]
LD = [("lb", 1), ("lh", 2), ("lw", 4), ("lbu", 1), ("lhu", 2)]
ST = [("sb", 1), ("sh", 2), ("sw", 4)]

# things that must trap as illegal: all zero, all ones, bad funct3 on loads / branches,
# csr instruction with funct3 4, a csr that doesn't exist, write to a read only csr
ILLEGAL = [0x00000000, 0xFFFFFFFF, 0x0000B003, 0x00002063, 0x00004073, 0x7C001073, 0xF1101073]


class Gen:
    def __init__(self, seed, n_blocks, irq, data=DATA, timing=True):
        self.data = data
        self.timing = timing        # False: nothing that depends on real time (board runs)
        self.r = random.Random(seed)
        self.n_blocks = n_blocks
        self.irq = irq
        self.out = []
        self.lab = 0
        self.funcs = []

    def emit(self, s):
        self.out.append("    " + s)

    def label(self):
        self.lab += 1
        return f"L{self.lab}"

    def reg(self):
        return self.r.choice(WORK + ["x0"] if self.r.random() < 0.05 else WORK)

    def src(self):
        return self.r.choice(WORK + ["x0"])

    def imm12(self):
        return self.r.choice([0, 1, -1, 2047, -2048, self.r.randint(-2048, 2047), self.r.randint(-16, 16)])

    def word(self):
        return self.r.choice([0, 1, 0xFFFFFFFF, 0x80000000, 0x7FFFFFFF, self.r.getrandbits(32),
                              self.r.getrandbits(8), self.r.getrandbits(16)])

    # ---------------- blocks ----------------
    def alu(self):
        c = self.r.random()
        if c < 0.4:
            self.emit(f"{self.r.choice(R)} {self.reg()}, {self.src()}, {self.src()}")
        elif c < 0.7:
            self.emit(f"{self.r.choice(I)} {self.reg()}, {self.src()}, {self.imm12()}")
        elif c < 0.85:
            self.emit(f"{self.r.choice(SH)} {self.reg()}, {self.src()}, {self.r.randint(0, 31)}")
        elif c < 0.93:
            self.emit(f"lui {self.reg()}, {self.r.getrandbits(20)}")
        else:
            self.emit(f"auipc {self.reg()}, {self.r.getrandbits(20)}")

    def mem(self):
        if self.r.random() < 0.5:
            op, size = self.r.choice(ST)
            off = self.r.randrange(0, 1024, size)
            self.emit(f"{op} {self.src()}, {off}(x29)")
        else:
            op, size = self.r.choice(LD)
            off = self.r.randrange(0, 1024, size)
            rd = self.reg()
            self.emit(f"{op} {rd}, {off}(x29)")
            if self.r.random() < 0.5:      # use it right away -> load-use stall
                self.emit(f"{self.r.choice(R)} {self.reg()}, {rd}, {self.src()}")

    def branch(self):
        end = self.label()
        self.emit(f"{self.r.choice(BR)} {self.src()}, {self.src()}, {end}")
        for _ in range(self.r.randint(0, 3)):
            self.alu()
        self.out.append(f"{end}:")

    def loop(self):
        top = self.label()
        self.emit(f"li x30, {self.r.randint(1, 5)}")
        self.out.append(f"{top}:")
        for _ in range(self.r.randint(1, 4)):
            self.r.choice([self.alu, self.alu, self.mem])()
        self.emit("addi x30, x30, -1")
        self.emit(f"bnez x30, {top}")

    def call(self):
        f = self.label()
        self.funcs.append(f)
        self.emit(f"jal x31, {f}")

    def jalr_skip(self):
        # computed jump over one instruction
        self.emit("auipc x21, 0")
        self.emit("jalr x0, 12(x21)")
        self.emit(f"addi {self.reg()}, {self.src()}, 1")     # skipped

    def csr(self):
        c = self.r.random()
        rd = self.reg()
        if c < 0.4:
            op = self.r.choice(["csrrw", "csrrs", "csrrc"])
            self.emit(f"{op} {rd}, mscratch, {self.src()}")
        elif c < 0.6:
            op = self.r.choice(["csrrwi", "csrrsi", "csrrci"])
            self.emit(f"{op} {rd}, mscratch, {self.r.randint(0, 31)}")
        elif c < 0.8:
            self.emit(f"csrr {rd}, {self.r.choice(['minstret', 'instret', 'minstreth', 'misa', 'mhartid', 'mtvec'])}")
        else:
            # mepc / mtval / mcause are plain registers when no trap is going on
            self.emit(f"csrrw {rd}, {self.r.choice(['mepc', 'mtval', 'mcause'])}, {self.src()}")

    def trap(self):
        c = self.r.randint(0, 7)
        if c == 0:
            self.emit("ecall")
        elif c == 1:
            self.emit("ebreak")
        elif c == 2:
            self.emit(f".word 0x{self.r.choice(ILLEGAL):08x}")
        elif c == 3:
            op, size = self.r.choice([("lh", 2), ("lw", 4), ("lhu", 2)])
            self.emit(f"{op} {self.reg()}, {self.r.randrange(1, 1024, 2) if size == 2 else self.r.randrange(1, 1024) | 1}(x29)")
        elif c == 4:
            op = self.r.choice(["sh", "sw"])
            self.emit(f"{op} {self.src()}, {self.r.randrange(1, 1024, 2)}(x29)")
        elif c == 5:
            # outside ram and io
            self.emit(f"li x21, 0x{self.r.choice([0x20000000, 0x10004000, 0x00010000, 0xFFFFFFFC]):08x}")
            self.emit(f"{self.r.choice(['lw', 'sw'])} x0, 0(x21)")
        elif c == 6:
            # jump to a misaligned address
            self.emit("auipc x21, 0")
            self.emit("jalr x0, 10(x21)")
        else:
            # jump to a bad address: fetch fault, the handler can't skip that one,
            # so it comes back via a known return address
            back = self.label()
            self.emit(f"la x22, {back}")
            self.emit("li x21, 0x20000000")
            self.emit("jalr x0, 0(x21)")
            self.out.append(f"{back}:")

    def io(self):
        c = self.r.random()
        if c < 0.4:
            self.emit(f"sw {self.src()}, 12(x20)")
            self.emit(f"lw {self.reg()}, 12(x20)")
        elif c < 0.6:
            self.emit(f"sb {self.src()}, 13(x20)")
            self.emit(f"lbu {self.reg()}, 12(x20)")
        elif c < 0.8 and self.timing:
            self.emit(f"lw {self.reg()}, 0(x28)")        # mtime, value comes from the trace
        else:
            self.emit(f"lw {self.reg()}, 8(x20)")        # clk_hz

    def selfmod(self):
        # write a new instruction into the code, fence.i, run it
        slot = self.label()
        rd = self.r.choice(WORK)
        imm = self.r.randint(-2048, 2047)
        word = ((imm & 0xFFF) << 20) | (int(rd[1:]) << 15) | (int(rd[1:]) << 7) | 0x13   # addi rd, rd, imm
        self.emit(f"la x21, {slot}")
        self.emit(f"li x22, 0x{word:08x}")
        self.emit("sw x22, 0(x21)")
        self.emit("fence.i")
        self.out.append(f"{slot}:")
        self.emit("nop")

    def body(self):
        kinds = [(self.alu, 30), (self.mem, 14), (self.branch, 8), (self.loop, 4), (self.call, 3),
                 (self.jalr_skip, 2), (self.csr, 5), (self.trap, 4), (self.io, 3), (self.selfmod, 1)]
        fns = [k for k, w in kinds for _ in range(w)]
        for _ in range(self.n_blocks):
            self.r.choice(fns)()

    def program(self):
        o = self.out
        o.append("    j start")
        o.append("")
        o.append("# trap handler: skip the instruction that trapped, keep a sum of the causes")
        o.append(".align 2")
        o.append("handler:")
        self.emit("csrr x26, mcause")
        self.emit("csrr x27, mepc")
        self.emit("bltz x26, irq")
        self.emit("csrr x25, mtval")
        self.emit("add x24, x24, x26")
        self.emit("xor x24, x24, x25")
        self.emit("li x21, 1")
        self.emit("bne x26, x21, h_skip")
        self.emit("mv x27, x22")          # fetch fault: go back to where it came from
        self.emit("j h_set")
        o.append("h_skip:")
        self.emit("addi x27, x27, 4")
        o.append("h_set:")
        self.emit("csrw mepc, x27")
        self.emit("mret")
        o.append("irq:")
        self.emit("addi x23, x23, 1")
        self.emit("lw x25, 0(x28)")
        self.emit(f"addi x25, x25, {self.r.randint(80, 600)}")
        self.emit("sw x25, 8(x28)")
        self.emit("sw x0, 12(x28)")
        self.emit("mret")
        o.append("")
        o.append("start:")
        self.emit("la x21, handler")
        self.emit("csrw mtvec, x21")
        self.emit(f"li x29, 0x{self.data:x}")
        self.emit(f"li x28, 0x{TIMER:x}")
        self.emit(f"li x20, 0x{SYS:x}")
        self.emit("li x22, 0")
        self.emit("li x23, 0")
        self.emit("li x24, 0")
        for rg in WORK:
            self.emit(f"li {rg}, 0x{self.word():08x}")
        if self.irq:
            self.emit("lw x25, 0(x28)")
            self.emit(f"addi x25, x25, {self.r.randint(50, 300)}")
            self.emit("sw x25, 8(x28)")
            self.emit("sw x0, 12(x28)")
            self.emit("li x21, 0x80")
            self.emit("csrs mie, x21")
            self.emit("csrsi mstatus, 8")
        self.body()
        self.emit("csrci mstatus, 8")
        # fold all work registers into a0 so the exit code depends on everything
        self.emit("li x21, 0")
        for rg in WORK:
            self.emit(f"xor x21, x21, {rg}")
        self.emit("xor x21, x21, x24")
        self.emit(f"li x22, 0x{SYS + 4:x}")
        self.emit("sw x21, 0(x22)")
        self.out.append("halt:")
        self.emit("j halt")
        for f in self.funcs:
            self.out.append(f"{f}:")
            for _ in range(self.r.randint(1, 4)):
                self.alu()
            self.emit("jalr x0, 0(x31)")
        # the data area is part of the image, so it starts out the same in the model,
        # the testbench and on the board (sdram comes up with junk in it)
        self.out.append(f".org 0x{self.data:x}")
        for _ in range(256):
            self.emit(f".word 0x{self.word():08x}")
        return "\n".join(self.out) + "\n"


def make(seed, n_blocks=150, irq=None, data=DATA, timing=True):
    """data = where the loads / stores go (block ram or sdram). timing=False leaves out
    the timer reads and interrupts, so the exit code can be checked on the board"""
    if irq is None:
        irq = timing and seed % 2 == 1
    return Gen(seed, n_blocks, irq, data, timing).program()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--blocks", type=int, default=150)
    ap.add_argument("--irq", action="store_true")
    ap.add_argument("-o", "--out", default="random.s")
    a = ap.parse_args()
    with open(a.out, "w") as f:
        f.write(make(a.seed, a.blocks, a.irq or None))


if __name__ == "__main__":
    main()
