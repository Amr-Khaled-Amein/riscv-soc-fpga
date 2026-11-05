"""
regression: python model + iverilog, everything has to pass

    python run_tests.py                  # everything (~7 min)
    python run_tests.py --random 200     # more random programs (default 60)
    python run_tests.py --no-mutants     # skip the broken design check
    python run_tests.py --no-c           # skip the c programs (needs gcc)
    python run_tests.py --seed 7

steps:
  1. assembler against gcc's assembler (if gcc is there)
  2. the model on its own: official tests, directed tests and c programs have to
     pass on rv_sim alone, so matching it means something
  3. sdram controller against the sdram model
  4. directed tests (tests/asm), from block ram and from sdram
  5. random programs, code / data in block ram or sdram, half with timer interrupts
  6. the official riscv-arch-test (act4) elfs: rv32i, zicsr, zifencei
  7. c programs (gcc): hello, bench, irq, fft benchmark
  8. whole design over the uart pins (tb_top)
  9. mutants: the rtl broken on purpose, every one has to make a test fail
 4-7 run on tb_soc with the commit trace checked against rv_sim, line by line
"""

import argparse
import glob
import json
import os
import random
import shutil
import subprocess
import sys
import time

import build_sw
import gen_random
import rv_asm
import rv_sim
import simrun
import top_test

ROOT = simrun.ROOT
SRC = simrun.SRC
ACT = os.path.join(ROOT, "tests", "act4", "elfs")
ASM = os.path.join(ROOT, "tests", "asm")
SD = 0x80000000


def act_files():
    return sorted(glob.glob(os.path.join(ACT, "*", "*.elf")))


def act_ok(r):
    return r["exit"] == 1 and b"TEST PASSED" in r["uart"]


# ------------------------------------------------------------------ 1: assembler

ASM_LINES = [
    "add x1, x2, x3", "sub x31, x0, x7", "sll a0, a1, a2", "slt s0, s1, t6", "sltu t0, t1, t2",
    "xor x5, x6, x7", "srl x8, x9, x10", "sra x11, x12, x13", "or x14, x15, x16", "and x17, x18, x19",
    "addi x1, x2, -2048", "addi x1, x2, 2047", "slti x3, x4, -1", "sltiu x5, x6, 100", "xori x7, x8, -1",
    "ori x9, x10, 0x555", "andi x11, x12, 255", "slli x1, x1, 31", "srli x2, x3, 1", "srai x4, x5, 17",
    "lui x6, 0xfffff", "auipc x7, 0x12345", "lb x1, -1(x2)", "lh x3, 2046(x4)", "lw x5, 0(x6)",
    "lbu x7, 100(x8)", "lhu x9, -100(x10)", "sb x1, -2048(x2)", "sh x3, 2047(x4)", "sw x5, 12(x6)",
    "jalr x1, 4(x2)", "jalr x0, 0(x1)", "csrrw x1, mscratch, x2", "csrrs x3, mstatus, x0",
    "csrrc x4, mie, x5", "csrrwi x6, mtvec, 31", "csrrsi x7, 0x7c0, 1", "csrrci x8, mepc, 0",
    "ecall", "ebreak", "mret", "wfi", "fence.i", "nop", "ret", "mv x1, x2", "not x3, x4", "neg x5, x6",
    "seqz x7, x8", "snez x9, x10", "csrr x1, minstret", "csrw mscratch, x2",
]


def check_assembler(gcc):
    """same words out of rv_asm and gcc for every instruction form, and for branches / jumps"""
    if not gcc:
        return None
    r = random.Random(3)
    lines = list(ASM_LINES)
    for _ in range(40):
        lines.append(f"beq x{r.randint(0, 31)}, x{r.randint(0, 31)}, L{r.randint(0, 9)}")
        lines.append(f"jal x{r.randint(0, 31)}, L{r.randint(0, 9)}")
        lines.append(f"bltu x{r.randint(0, 31)}, x{r.randint(0, 31)}, L{r.randint(0, 9)}")
    body = []
    for i, l in enumerate(lines):
        if i % 12 == 0:
            body.append(f"L{i // 12}:")
        body.append("    " + l)
    for i in range(len(lines) // 12 + 1, 10):
        body.append(f"L{i}:")
    text = "\n".join(body) + "\n"
    mine = rv_asm.to_words(rv_asm.assemble(text)[0])
    d = simrun.build_dir("asmcheck")
    with open(os.path.join(d, "t.s"), "w") as f:
        f.write(".option norvc\n.option norelax\n" + text)
    objcopy = build_sw.tool(gcc, "objcopy")
    subprocess.run([gcc, "-march=rv32i_zicsr_zifencei", "-mabi=ilp32", "-c", "-o", "t.o", "t.s"], cwd=d, check=True)
    subprocess.run([objcopy, "-O", "binary", "-j", ".text", "t.o", "t.bin"], cwd=d, check=True)
    with open(os.path.join(d, "t.bin"), "rb") as f:
        b = f.read()
    theirs = [int.from_bytes(b[i:i + 4], "little") for i in range(0, len(b), 4)]
    bad = [i for i, (x, y) in enumerate(zip(mine, theirs)) if x != y]
    if len(mine) != len(theirs) or bad:
        return [f"word {i}: rv_asm {mine[i]:08x}, gcc {theirs[i]:08x}" for i in bad[:5]] or ["length differs"]
    return []


# ------------------------------------------------------------------ 2: model alone

def check_model(c_elfs):
    errs = []
    for f in act_files():
        segs, syms = simrun.image_from_elf(f)
        h = rv_sim.Hart()
        for a, d in segs:
            h.load_image(d, a)
        h.pc = syms["_entry"]
        rv_sim.run(h, 2_000_000)
        if h.io.exit != 1 or b"TEST PASSED" not in h.io.out:
            errs.append(f"model fails {os.path.basename(f)}")
    for f in sorted(glob.glob(os.path.join(ASM, "*.s"))):
        segs, _ = simrun.image_from_asm(f)
        h = rv_sim.Hart()
        for a, d in segs:
            h.load_image(d, a)
        rv_sim.run(h, 1_000_000)
        if h.io.exit != 0:
            errs.append(f"model: {os.path.basename(f)} exits {h.io.exit}")
    for name, f in c_elfs.items():
        if name == "irq":
            continue                # needs the real timer
        segs, syms = simrun.image_from_elf(f)
        h = rv_sim.Hart()
        for a, d in segs:
            h.load_image(d, a)
        rv_sim.run(h, 50_000_000)
        if h.io.exit != 0:
            errs.append(f"model: {name} exits {h.io.exit}")
    return errs


# ------------------------------------------------------------------ 3: sdram

def check_sdram(src=SRC):
    d = simrun.build_dir("sdram")
    simrun.sh(["iverilog", "-g2012", "-Wall", "-Wno-timescale", "-o", "sd.vvp", os.path.join(simrun.SIM, "tb_sdram.sv"),
               os.path.join(simrun.SIM, "sdram_model.sv"), os.path.join(src, "sdram_ctrl.v")], d)
    out = simrun.sh(["vvp", "-n", "sd.vvp"], d)
    return [l for l in out.splitlines() if l.startswith(("PASS", "FAIL"))][-1]


# ------------------------------------------------------------------ 4-7 on tb_soc

def directed(d, vvp, stop_early=False, max_cycles=2_000_000):
    rows = []
    for f in sorted(glob.glob(os.path.join(ASM, "*.s"))):
        name = os.path.basename(f)[:-2]
        for base in (0, SD):
            if name == "sdram" and base:
                continue
            segs, _ = simrun.image_from_asm(f, base=base)
            r = simrun.run(d, vvp, segs, pc=base, max_cycles=max_cycles)
            ok = simrun.ok(r) and r["exit"] == 0
            rows.append({"name": name, "where": "sdram" if base else "bram", "ok": ok, "exit": r["exit"],
                         "cycles": r["cycles"], "instret": r["instret"], "err": r.get("errors", [])[:1]})
            if stop_early and not ok:
                return rows
    return rows


def random_programs(d, vvp, n, seed, stop_early=False, max_cycles=2_000_000):
    rows = []
    for i in range(n):
        s = seed * 1000 + i
        code = SD if i % 3 == 2 else 0
        data = 0x80100000 if i % 4 == 3 else 0x8000
        segs, _ = simrun.image_from_asm(gen_random.make(s, 300, data=data), True, code)
        r = simrun.run(d, vvp, segs, pc=code, max_cycles=max_cycles)
        ok = simrun.ok(r)
        rows.append({"seed": s, "ok": ok, "instret": r["instret"], "cycles": r["cycles"],
                     "err": r.get("errors", [])[:1]})
        if stop_early and not ok:
            break
    return rows


def act(d, vvp, files, stop_early=False):
    rows = []
    for f in files:
        segs, syms = simrun.image_from_elf(f)
        r = simrun.run(d, vvp, segs, pc=syms["_entry"], max_cycles=5_000_000)
        ok = act_ok(r) and simrun.ok(r)
        rows.append({"name": os.path.basename(f)[:-4], "ok": ok, "cycles": r["cycles"], "instret": r["instret"],
                     "checked": r.get("checked", 0), "err": r.get("errors", [])[:1]})
        if stop_early and not ok:
            break
    return rows


def c_programs(d, vvp, elfs):
    rows = []
    for name, f in elfs.items():
        segs, syms = simrun.image_from_elf(f)
        r = simrun.run(d, vvp, segs, pc=syms["_entry"], max_cycles=5_000_000)
        rows.append({"name": name, "ok": simrun.ok(r) and r["exit"] == 0, "cycles": r["cycles"],
                     "instret": r["instret"], "out": r["uart"].decode("latin1"), "err": r.get("errors", [])[:1]})
    return rows


# ------------------------------------------------------------------ 9: mutants

# (what it breaks, file, old text, new text). the old text has to be in the file
MUTANTS = [
    ("no forwarding from MEM", "rv_core.v", "wire fwd_a_mem = ex_fa_mem & mem_rd_we;", "wire fwd_a_mem = 1'b0;"),
    ("no forwarding from WB", "rv_core.v", "wire fwd_b_wb  = ex_fb_wb & wb_rd_we;", "wire fwd_b_wb  = 1'b0;"),
    ("WB forward wins over MEM", "rv_core.v",
     "wire [31:0] rs1_v = fwd_a_mem ? mem_result : fwd_a_wb ? wb_data : ex_rs1_val;",
     "wire [31:0] rs1_v = fwd_a_wb ? wb_data : fwd_a_mem ? mem_result : ex_rs1_val;"),
    ("x0 gets forwarded", "rv_core.v", "wire fa_mem = ex_valid & ex_rd_we & (ex_rd != 5'd0) & (ex_rd == id_rs1);",
     "wire fa_mem = ex_valid & ex_rd_we & (ex_rd == id_rs1);"),
    ("no load-use stall", "rv_core.v", "assign stall = ex_valid & ex_load", "assign stall = 1'b0 & ex_load"),
    ("regfile doesn't pass WB through", "rv_core.v",
     "(wb_we && wb_rd == id_rs2) ? wb_data : rf[id_rs2];", "rf[id_rs2];"),
    ("wrong guess on a backward branch not fixed", "rv_core.v", "(take != ex_pred)", "(take & ~ex_pred)"),
    ("ecall gives the wrong cause", "rv_core.v", "exc_cause = 32'd11;", "exc_cause = 32'd8;"),
    ("lb not sign extended", "rv_core.v", "3'd0: ld = {{24{sh[7]}}, sh[7:0]};", "3'd0: ld = {24'd0, sh[7:0]};"),
    ("sh always writes the low half", "rv_core.v", "strb = addr[1] ? 4'b1100 : 4'b0011;", "strb = 4'b0011;"),
    ("jalr doesn't clear bit 0", "rv_core.v", "{addr[31:1], 1'b0}", "addr"),
    ("sra is srl", "rv_alu.v", "4'b1101: y = $signed(a) >>> sh;", "4'b1101: y = a >> sh;"),
    ("sltu is signed", "rv_alu.v", "4'b0011, 4'b1011: y = {31'd0, a < b};",
     "4'b0011, 4'b1011: y = {31'd0, $signed(a) < $signed(b)};"),
    ("misaligned load doesn't trap", "rv_core.v", "end else if (ex_load && misal) begin", "end else if (1'b0) begin"),
    ("illegal instruction doesn't trap", "rv_core.v", "end else if (ex_illegal || csr_illegal) begin",
     "end else if (csr_illegal) begin"),
    ("trapped instruction still writes its register", "rv_core.v", "mem_rd_we  <= ex_rd_we & ~trap;",
     "mem_rd_we  <= ex_rd_we;"),
    ("mscratch can't be written", "rv_csr.v", "12'h340: mscratch <= wval;", "12'h340: mscratch <= mscratch;"),
    ("mepc not saved on a trap", "rv_csr.v", "mepc   <= {epc[31:2], 2'b00};", "mepc   <= mepc;"),
    ("mret doesn't turn interrupts back on", "rv_csr.v", "mie_b  <= mpie_b;", "mie_b  <= 1'b0;"),
    ("interrupt ignores mstatus.MIE", "rv_csr.v", "assign irq     = mie_b & mtie & irq_timer;",
     "assign irq     = mtie & irq_timer;"),
    ("minstret counts trapped instructions", "rv_core.v", ".retire(~trap)", ".retire(1'b1)"),
    ("fence.i doesn't refetch", "rv_core.v", "(trap | ex_mret | ex_fencei | (take != ex_pred))",
     "(trap | ex_mret | (take != ex_pred))"),
    ("fetch buffer not cleared by a store to sdram", "soc.v", "            if (p0_ack && p0_we)\n                fb_valid <= 1'b0;",
     ""),
    ("sdram read data caught a clock late", "sdram_ctrl.v", "if (step >= 4'd3 && step <= 4'd6)",
     "if (step >= 4'd4 && step <= 4'd7)"),
    ("axi read data from the wrong slave", "axil_xbar.v", "s_rdata   = m_rdata[32*r_sel +: 32];",
     "s_rdata   = m_rdata[31:0];"),
    ("interconnect drops the byte strobes", "axil_xbar.v", "assign m_wstrb  = s_wstrb;", "assign m_wstrb  = 4'hf;"),
    ("fft done flag not cleared by start", "fft_axi.v", "                done_f <= 1'b0;\n                cycles <= 32'd0;",
     "                cycles <= 32'd0;"),
    ("sys ignores byte strobes", "sys_axi.v", "scratch <= merge(scratch, wr_data, wr_strb);", "scratch <= wr_data;"),
    ("loader starts the cpu before reset_pc is set", "host_link.v", "                            st       <= S_GO;",
     "                            st       <= S_RUN;"),
]

QUICK_ACT = ["I-add-00", "I-lb-00", "I-sh-00", "I-jalr-00", "I-bltu-00", "Zicsr-csrrw-00", "Zifencei-fence.i-00"]


def run_mutants(seed):
    files = [f for f in act_files() if os.path.basename(f)[:-4] in QUICK_ACT]
    results = []
    for name, fname, old, new in MUTANTS:
        d = simrun.build_dir("mutant")
        msrc = os.path.join(d, "src")
        if os.path.exists(msrc):
            shutil.rmtree(msrc)
        shutil.copytree(SRC, msrc)
        p = os.path.join(msrc, fname)
        with open(p) as f:
            text = f.read()
        if text.count(old) != 1:
            raise RuntimeError(f"mutant '{name}': text not found once in {fname}")
        with open(p, "w") as f:
            f.write(text.replace(old, new))
        caught = None
        if fname in ("host_link.v", "top.v"):
            caught = "uart" if top_test.run(msrc) else None
        else:
            # a mutant that doesn't compile is a broken mutant, not a catch -> sh() raises
            vvp = simrun.compile_soc(d, msrc)
            # these all finish in < 20k clocks, a mutant that hangs shouldn't take minutes
            if not all(r["ok"] for r in directed(d, vvp, True, 100_000)):
                caught = "directed"
            elif not all(r["ok"] for r in random_programs(d, vvp, 12, seed + 50, True, 100_000)):
                caught = "random"
            elif not all(r["ok"] for r in act(d, vvp, files, True)):
                caught = "act4"
            elif "PASS" not in check_sdram(msrc):
                caught = "sdram tb"
            elif top_test.run(msrc):
                caught = "uart"
        results.append((name, caught))
        print(f"  {'caught' if caught else 'MISSED':7s} {name}" + (f"  ({caught})" if caught else ""), flush=True)
    return results


# ------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--random", type=int, default=60)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--no-c", action="store_true")
    ap.add_argument("--no-act", action="store_true")
    ap.add_argument("--no-mutants", action="store_true")
    a = ap.parse_args()

    if not shutil.which("iverilog"):
        print("iverilog not on PATH")
        sys.exit(1)
    t_all = time.time()
    fails = 0
    summary = {}

    gcc = None if a.no_c else build_sw.find_gcc()
    c_elfs = {}
    if gcc:
        c_elfs["hello"] = build_sw.build("hello", gcc)
        c_elfs["bench"] = build_sw.build("bench", gcc)
        c_elfs["irq"] = build_sw.build("irq", gcc, ["TICK=3000"], "irq_sim")
        c_elfs["fft_bench"] = build_sw.build("fft_bench", gcc, ["NSIG=1"], "fft_bench_sim")

    e = check_assembler(gcc)
    print("assembler vs gcc ...", "skipped (no gcc)" if e is None else "ok" if not e else "FAIL")
    for x in (e or [])[:5]:
        print("     ", x)
    fails += bool(e)

    e = check_model(c_elfs)
    print(f"model alone passes the official tests, directed tests and c programs ...", "ok" if not e else "FAIL")
    for x in e[:5]:
        print("     ", x)
    fails += bool(e)

    line = check_sdram()
    print("sdram controller vs sdram model ...", line)
    fails += not line.startswith("PASS")

    d = simrun.build_dir("soc")
    vvp = simrun.compile_soc(d)

    print("\ndirected tests (exit 0 + every instruction matches the model):")
    rows = directed(d, vvp)
    for r in rows:
        print(f"  {r['name']:10s} {r['where']:6s} {'ok' if r['ok'] else 'FAIL':5s} {r['instret']:6d} instr "
              f"{r['cycles']:7d} clocks" + (f"  {r['err']}" if not r["ok"] else ""))
    summary["directed"] = rows
    fails += sum(not r["ok"] for r in rows)

    if a.random:
        t0 = time.time()
        rows = random_programs(d, vvp, a.random, a.seed)
        nbad = sum(not r["ok"] for r in rows)
        print(f"\n{a.random} random programs (seed {a.seed}): {'PASS' if not nbad else f'{nbad} FAILED'}, "
              f"{sum(r['instret'] for r in rows)} instructions checked ({time.time() - t0:.0f}s)")
        for r in rows:
            if not r["ok"]:
                print(f"  FAIL seed {r['seed']}: {r['err']}")
        summary["random"] = {"count": a.random, "failed": nbad, "instructions": sum(r["instret"] for r in rows)}
        fails += nbad

    if not a.no_act:
        t0 = time.time()
        rows = act(d, vvp, act_files())
        nok = sum(r["ok"] for r in rows)
        print(f"\nofficial riscv-arch-test (act4): {nok}/{len(rows)} passed, "
              f"{sum(r['checked'] for r in rows)} instructions matched the model ({time.time() - t0:.0f}s)")
        for r in rows:
            if not r["ok"]:
                print(f"  FAIL {r['name']} {r['err']}")
        summary["act"] = rows
        fails += len(rows) - nok

    if c_elfs:
        print("\nc programs:")
        rows = c_programs(d, vvp, c_elfs)
        for r in rows:
            print(f"  {r['name']:10s} {'ok' if r['ok'] else 'FAIL':5s} {r['instret']:8d} instr {r['cycles']:8d} clocks")
            for line in r["out"].strip().splitlines():
                print("      " + line)
        summary["c"] = rows
        fails += sum(not r["ok"] for r in rows)

    e = top_test.run()
    print("\nwhole design over the uart pins ...", "PASS" if not e else "FAIL")
    for x in e:
        print("     ", x)
    fails += bool(e)

    if not a.no_mutants:
        print("\nmutants (broken on purpose, each one has to be caught):")
        res = run_mutants(a.seed)
        missed = sum(1 for _, c in res if not c)
        print(f"  {len(res) - missed}/{len(res)} caught")
        summary["mutants"] = {"total": len(res), "caught": len(res) - missed}
        fails += missed

    with open(os.path.join(simrun.BUILD, "summary.json"), "w") as f:
        json.dump(summary, f, indent=1)
    print(f"\nALL PASS ({time.time() - t_all:.0f}s)" if not fails else f"\n{fails} FAILED")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
