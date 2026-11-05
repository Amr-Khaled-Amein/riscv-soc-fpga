"""
small rv32i assembler, enough for the hand written and random tests
(the c programs and the official tests go through gcc)

    python rv_asm.py prog.s -o prog.hex       # one 32 bit word per line, from address 0

knows rv32i + zicsr + fence.i, the usual pseudo instructions (li la mv not neg j jr
ret call beqz bnez bgt ble seqz snez csrr csrw ...), labels, %hi / %lo and
.org .word .half .byte .space .align .ascii .asciz .equ
"""

import argparse
import re
import sys

REGS = {f"x{i}": i for i in range(32)}
ABI = ["zero", "ra", "sp", "gp", "tp", "t0", "t1", "t2", "s0", "s1", "a0", "a1", "a2", "a3", "a4", "a5",
       "a6", "a7", "s2", "s3", "s4", "s5", "s6", "s7", "s8", "s9", "s10", "s11", "t3", "t4", "t5", "t6"]
REGS.update({n: i for i, n in enumerate(ABI)})
REGS["fp"] = 8

CSRS = {
    "mstatus": 0x300, "misa": 0x301, "mie": 0x304, "mtvec": 0x305, "mstatush": 0x310,
    "mcountinhibit": 0x320, "mscratch": 0x340, "mepc": 0x341, "mcause": 0x342, "mtval": 0x343,
    "mip": 0x344, "mcycle": 0xB00, "minstret": 0xB02, "mcycleh": 0xB80, "minstreth": 0xB82,
    "cycle": 0xC00, "instret": 0xC02, "cycleh": 0xC80, "instreth": 0xC82,
    "mvendorid": 0xF11, "marchid": 0xF12, "mimpid": 0xF13, "mhartid": 0xF14, "mconfigptr": 0xF15,
}

R_OPS = {  # funct7, funct3
    "add": (0, 0), "sub": (0x20, 0), "sll": (0, 1), "slt": (0, 2), "sltu": (0, 3),
    "xor": (0, 4), "srl": (0, 5), "sra": (0x20, 5), "or": (0, 6), "and": (0, 7),
}
I_OPS = {"addi": 0, "slti": 2, "sltiu": 3, "xori": 4, "ori": 6, "andi": 7}
SH_OPS = {"slli": (0, 1), "srli": (0, 5), "srai": (0x20, 5)}
LOADS = {"lb": 0, "lh": 1, "lw": 2, "lbu": 4, "lhu": 5}
STORES = {"sb": 0, "sh": 1, "sw": 2}
BRANCHES = {"beq": 0, "bne": 1, "blt": 4, "bge": 5, "bltu": 6, "bgeu": 7}
CSR_OPS = {"csrrw": 1, "csrrs": 2, "csrrc": 3, "csrrwi": 5, "csrrsi": 6, "csrrci": 7}


class AsmError(Exception):
    pass


def r_type(f7, rs2, rs1, f3, rd, op):
    return (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op


def i_type(imm, rs1, f3, rd, op):
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op


def s_type(imm, rs2, rs1, f3, op):
    imm &= 0xFFF
    return ((imm >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | ((imm & 0x1F) << 7) | op


def b_type(imm, rs2, rs1, f3):
    imm &= 0x1FFF
    return (((imm >> 12) & 1) << 31) | (((imm >> 5) & 0x3F) << 25) | (rs2 << 20) | (rs1 << 15) | \
           (f3 << 12) | (((imm >> 1) & 0xF) << 8) | (((imm >> 11) & 1) << 7) | 0x63


def u_type(imm, rd, op):
    return (imm & 0xFFFFF000) | (rd << 7) | op


def j_type(imm, rd):
    imm &= 0x1FFFFF
    return (((imm >> 20) & 1) << 31) | (((imm >> 1) & 0x3FF) << 21) | (((imm >> 11) & 1) << 20) | \
           (((imm >> 12) & 0xFF) << 12) | (rd << 7) | 0x6F


def hi20(v):
    """upper part for lui/auipc so that hi + sign extended lo = v"""
    return ((v + 0x800) >> 12) & 0xFFFFF


def lo12(v):
    v &= 0xFFF
    return v - 0x1000 if v & 0x800 else v


class Assembler:
    def __init__(self):
        self.syms = {}

    def reg(self, s):
        s = s.strip()
        if s not in REGS:
            raise AsmError(f"bad register '{s}'")
        return REGS[s]

    def value(self, s, pc=0):
        """number, symbol, %hi(x) / %lo(x), or a simple + - expression of those"""
        s = s.strip()
        m = re.fullmatch(r"%(hi|lo|pcrel_hi|pcrel_lo)\((.+)\)", s)
        if m:
            v = self.value(m.group(2), pc)
            if m.group(1) == "hi":
                return hi20(v)
            if m.group(1) == "pcrel_hi":
                return hi20(v - pc)
            return lo12(v)
        if s.startswith("'") and s.endswith("'") and len(s) == 3:
            return ord(s[1])
        total, sign, tok = 0, 1, ""
        for ch in s + "+":
            if ch in "+-" and tok.strip():
                total += sign * self.atom(tok.strip())
                sign, tok = (1 if ch == "+" else -1), ""
            elif ch in "+-" and not tok.strip():
                sign = -sign if ch == "-" else sign
            else:
                tok += ch
        return total

    def atom(self, t):
        if t in self.syms:
            return self.syms[t]
        if t == ".":
            return self.cur
        try:
            return int(t, 0)
        except ValueError:
            if self.final:
                raise AsmError(f"unknown symbol '{t}'")
            return 0

    def mem_operand(self, s):
        m = re.fullmatch(r"(.*)\((\w+)\)", s.strip())
        if not m:
            raise AsmError(f"expected offset(reg), got '{s}'")
        off = self.value(m.group(1)) if m.group(1).strip() else 0
        return off, self.reg(m.group(2))

    def csr(self, s):
        s = s.strip()
        return CSRS[s] if s in CSRS else self.value(s)

    def li_words(self, rd, v):
        v &= 0xFFFFFFFF
        sv = v - (1 << 32) if v & 0x80000000 else v
        if -2048 <= sv < 2048:
            return [i_type(sv, 0, 0, rd, 0x13)]
        out = [u_type(hi20(v) << 12, rd, 0x37)]
        if lo12(v):
            out.append(i_type(lo12(v), rd, 0, rd, 0x13))
        return out

    def size_of(self, mn, ops):
        """bytes an instruction will take, has to agree with encode()"""
        if mn == "li":
            if not self.final:
                # pass 1 doesn't know labels yet, size it from what we can see
                try:
                    return 4 * len(self.li_words(0, int(ops[1], 0)))
                except ValueError:
                    return 4 * len(self.li_words(0, self.value(ops[1])))
            return 4 * len(self.li_words(0, self.value(ops[1])))
        if mn == "la":
            return 8
        return 4

    def encode(self, mn, ops, pc):
        n = len(ops)
        if mn in R_OPS:
            f7, f3 = R_OPS[mn]
            return [r_type(f7, self.reg(ops[2]), self.reg(ops[1]), f3, self.reg(ops[0]), 0x33)]
        if mn in I_OPS:
            imm = self.value(ops[2], pc)
            if not -2048 <= imm < 2048:
                raise AsmError(f"immediate {imm} out of range")
            return [i_type(imm, self.reg(ops[1]), I_OPS[mn], self.reg(ops[0]), 0x13)]
        if mn in SH_OPS:
            f7, f3 = SH_OPS[mn]
            sh = self.value(ops[2])
            if not 0 <= sh < 32:
                raise AsmError("shift amount out of range")
            return [r_type(f7, sh, self.reg(ops[1]), f3, self.reg(ops[0]), 0x13)]
        if mn in LOADS:
            off, base = self.mem_operand(ops[1])
            return [i_type(off, base, LOADS[mn], self.reg(ops[0]), 0x03)]
        if mn in STORES:
            off, base = self.mem_operand(ops[1])
            return [s_type(off, self.reg(ops[0]), base, STORES[mn], 0x23)]
        if mn in BRANCHES:
            off = self.value(ops[2]) - pc
            if self.final and not -4096 <= off < 4096:
                raise AsmError("branch target too far")
            return [b_type(off, self.reg(ops[1]), self.reg(ops[0]), BRANCHES[mn])]
        if mn == "lui":
            return [u_type(self.value(ops[1], pc) << 12, self.reg(ops[0]), 0x37)]
        if mn == "auipc":
            return [u_type(self.value(ops[1], pc) << 12, self.reg(ops[0]), 0x17)]
        if mn == "jal":
            rd, tgt = (1, ops[0]) if n == 1 else (self.reg(ops[0]), ops[1])
            return [j_type(self.value(tgt) - pc, rd)]
        if mn == "jalr":
            if n == 1:
                return [i_type(0, self.reg(ops[0]), 0, 1, 0x67)]
            if n == 2 and "(" in ops[1]:
                off, base = self.mem_operand(ops[1])
                return [i_type(off, base, 0, self.reg(ops[0]), 0x67)]
            return [i_type(self.value(ops[2]), self.reg(ops[1]), 0, self.reg(ops[0]), 0x67)]
        if mn in CSR_OPS:
            src = self.value(ops[2]) if mn.endswith("i") else self.reg(ops[2])
            return [i_type(self.csr(ops[1]), src, CSR_OPS[mn], self.reg(ops[0]), 0x73)]
        if mn == "ecall":
            return [0x00000073]
        if mn == "ebreak":
            return [0x00100073]
        if mn == "mret":
            return [0x30200073]
        if mn == "wfi":
            return [0x10500073]
        if mn == "fence":
            return [0x0FF0000F]
        if mn == "fence.i":
            return [0x0000100F]

        # pseudo instructions
        if mn == "nop":
            return [0x00000013]
        if mn == "li":
            return self.li_words(self.reg(ops[0]), self.value(ops[1]))
        if mn == "la":
            off = self.value(ops[1]) - pc
            rd = self.reg(ops[0])
            return [u_type(hi20(off) << 12, rd, 0x17), i_type(lo12(off), rd, 0, rd, 0x13)]
        if mn == "mv":
            return [i_type(0, self.reg(ops[1]), 0, self.reg(ops[0]), 0x13)]
        if mn == "not":
            return [i_type(-1, self.reg(ops[1]), 4, self.reg(ops[0]), 0x13)]
        if mn == "neg":
            return [r_type(0x20, self.reg(ops[1]), 0, 0, self.reg(ops[0]), 0x33)]
        if mn == "seqz":
            return [i_type(1, self.reg(ops[1]), 3, self.reg(ops[0]), 0x13)]
        if mn == "snez":
            return [r_type(0, self.reg(ops[1]), 0, 3, self.reg(ops[0]), 0x33)]
        if mn == "j":
            return [j_type(self.value(ops[0]) - pc, 0)]
        if mn == "call":
            return [j_type(self.value(ops[0]) - pc, 1)]
        if mn == "jr":
            return [i_type(0, self.reg(ops[0]), 0, 0, 0x67)]
        if mn == "ret":
            return [i_type(0, 1, 0, 0, 0x67)]
        if mn in ("beqz", "bnez", "bltz", "bgez"):
            base = {"beqz": "beq", "bnez": "bne", "bltz": "blt", "bgez": "bge"}[mn]
            return self.encode(base, [ops[0], "zero", ops[1]], pc)
        if mn in ("blez", "bgtz"):
            base = {"blez": "bge", "bgtz": "blt"}[mn]
            return self.encode(base, ["zero", ops[0], ops[1]], pc)
        if mn in ("bgt", "ble", "bgtu", "bleu"):
            base = {"bgt": "blt", "ble": "bge", "bgtu": "bltu", "bleu": "bgeu"}[mn]
            return self.encode(base, [ops[1], ops[0], ops[2]], pc)
        if mn == "csrr":
            return self.encode("csrrs", [ops[0], ops[1], "zero"], pc)
        if mn in ("csrw", "csrs", "csrc"):
            return self.encode("csrr" + mn[3], ["zero", ops[0], ops[1]], pc)
        if mn in ("csrwi", "csrsi", "csrci"):
            return self.encode("csrr" + mn[3] + "i", ["zero", ops[0], ops[1]], pc)
        raise AsmError(f"unknown instruction '{mn}'")

    def parse(self, text):
        """-> list of (line number, label list, mnemonic or directive, operand list)"""
        out = []
        for ln, line in enumerate(text.splitlines(), 1):
            line = re.split(r"#|//", line, maxsplit=1)[0] if '"' not in line else line.split("#")[0]
            line = line.strip()
            labels = []
            while True:
                m = re.match(r"^([A-Za-z_.$][\w.$]*):\s*(.*)$", line)
                if not m:
                    break
                labels.append(m.group(1))
                line = m.group(2)
            if not line:
                out.append((ln, labels, None, []))
                continue
            parts = line.split(None, 1)
            mn = parts[0].lower()
            rest = parts[1] if len(parts) > 1 else ""
            if mn in (".ascii", ".asciz", ".string"):
                ops = [rest.strip()]
            else:
                ops = [o.strip() for o in re.split(r",(?![^(]*\))", rest)] if rest.strip() else []
            out.append((ln, labels, mn, ops))
        return out

    def run_pass(self, lines):
        mem = {}
        pc = 0
        for ln, labels, mn, ops in lines:
            self.cur = pc
            try:
                for lab in labels:
                    if not self.final and lab in self.syms and self.syms[lab] != pc and lab in self.defined:
                        raise AsmError(f"label '{lab}' defined twice")
                    self.syms[lab] = pc
                    self.defined.add(lab)
                if mn is None:
                    continue
                if mn == ".org":
                    pc = self.value(ops[0])
                elif mn in (".equ", ".set"):
                    self.syms[ops[0]] = self.value(ops[1])
                elif mn == ".align":
                    a = 1 << self.value(ops[0])
                    while pc % a:
                        mem[pc] = 0
                        pc += 1
                elif mn in (".word", ".half", ".byte"):
                    size = {".word": 4, ".half": 2, ".byte": 1}[mn]
                    for o in ops:
                        v = self.value(o) & ((1 << (8 * size)) - 1)
                        for i in range(size):
                            mem[pc + i] = (v >> (8 * i)) & 0xFF
                        pc += size
                elif mn == ".space":
                    for i in range(self.value(ops[0])):
                        mem[pc + i] = 0
                    pc += self.value(ops[0])
                elif mn in (".ascii", ".asciz", ".string"):
                    s = ops[0].strip()
                    if not (s.startswith('"') and s.endswith('"')):
                        raise AsmError("expected a string")
                    data = s[1:-1].encode().decode("unicode_escape").encode("latin1")
                    if mn != ".ascii":
                        data += b"\0"
                    for b in data:
                        mem[pc] = b
                        pc += 1
                elif mn.startswith("."):
                    pass            # .text .data .globl ... nothing to do
                else:
                    if pc % 4:
                        raise AsmError("instruction not word aligned")
                    if self.final:
                        words = self.encode(mn, ops, pc)
                        if len(words) * 4 != self.sizes[(ln, pc)]:
                            raise AsmError("size changed between passes (li with a forward label?)")
                    else:
                        words = [0] * (self.size_of(mn, ops) // 4)
                        self.sizes[(ln, pc)] = len(words) * 4
                    for w in words:
                        for i in range(4):
                            mem[pc + i] = (w >> (8 * i)) & 0xFF
                        pc += 4
            except (AsmError, IndexError, KeyError, ValueError) as e:
                raise AsmError(f"line {ln}: {e}") from None
        return mem

    def assemble(self, text):
        lines = self.parse(text)
        self.final, self.sizes, self.defined = False, {}, set()
        self.run_pass(lines)
        # second pass with all labels known. sizes are fixed from pass 1
        self.final, self.defined = True, set()
        sizes = dict(self.sizes)
        self.sizes = sizes
        return self.run_pass(lines)


def assemble(text):
    """-> (dict addr -> byte, symbols)"""
    a = Assembler()
    mem = a.assemble(text)
    return mem, a.syms


def to_words(mem, nwords=None):
    top = max(mem) + 1 if mem else 0
    n = nwords or (top + 3) // 4
    return [sum(mem.get(4 * i + k, 0) << (8 * k) for k in range(4)) for i in range(n)]


def to_bytes(mem):
    top = max(mem) + 1 if mem else 0
    return bytes(mem.get(i, 0) for i in range(top))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src")
    ap.add_argument("-o", "--out", default=None)
    a = ap.parse_args()
    with open(a.src) as f:
        try:
            mem, _ = assemble(f.read())
        except AsmError as e:
            print(f"{a.src}: {e}")
            sys.exit(1)
    words = to_words(mem)
    out = a.out or a.src.rsplit(".", 1)[0] + ".hex"
    with open(out, "w") as f:
        f.writelines(f"{w:08x}\n" for w in words)
    print(f"{out}: {len(words)} words")


if __name__ == "__main__":
    main()
