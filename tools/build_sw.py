"""
builds the c programs in sw/ with gcc -> build/sw/<name>.elf (+ .dis listing)

    python build_sw.py              # all of them
    python build_sw.py fft_bench

gcc: $RISCV_GCC, or riscv-none-elf-gcc / riscv64-unknown-elf-gcc on the path,
or the xpack one in D:/riscv
"""

import glob
import os
import shutil
import subprocess
import sys

import gen_twiddle

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, ".."))
SW = os.path.join(ROOT, "sw")
OUT = os.path.join(ROOT, "build", "sw")

CFLAGS = ["-march=rv32i_zicsr", "-mabi=ilp32", "-O2", "-ffreestanding", "-fno-builtin", "-nostdlib",
          "-nostartfiles", "-Wall", "-Wextra", "-Wno-unused-parameter", "-g"]


def find_gcc():
    if os.environ.get("RISCV_GCC"):
        return os.environ["RISCV_GCC"]
    for name in ("riscv-none-elf-gcc", "riscv64-unknown-elf-gcc", "riscv32-unknown-elf-gcc"):
        p = shutil.which(name)
        if p:
            return p
    for p in glob.glob("D:/riscv/xpack-riscv-none-elf-gcc-*/bin/riscv-none-elf-gcc.exe"):
        return p
    return None


def tool(gcc, name):
    """riscv-...-gcc(.exe) -> riscv-...-<name>(.exe) in the same folder"""
    d, b = os.path.split(gcc)
    return os.path.join(d, b.replace("gcc", name))


def twiddle_header(path):
    tw = gen_twiddle.twiddles(256, 16)
    with open(path, "w") as f:
        f.write("// made by tools/build_sw.py from gen_twiddle.twiddles(256, 16), same as the rom\n")
        f.write("static const int16_t tw_cos[128] = {\n")
        f.write(",\n".join("    " + ", ".join(str(c) for c, _ in tw[i:i + 8]) for i in range(0, 128, 8)))
        f.write("\n};\nstatic const int16_t tw_sin[128] = {\n")
        f.write(",\n".join("    " + ", ".join(str(s) for _, s in tw[i:i + 8]) for i in range(0, 128, 8)))
        f.write("\n};\n")


def build(name, gcc=None, defines=(), out_name=None):
    gcc = gcc or find_gcc()
    if not gcc:
        raise RuntimeError("no risc-v gcc found (set RISCV_GCC)")
    os.makedirs(OUT, exist_ok=True)
    twiddle_header(os.path.join(OUT, "twiddle.h"))
    elf = os.path.join(OUT, (out_name or name) + ".elf")
    cmd = [gcc] + CFLAGS + [f"-D{d}" for d in defines] + ["-I", os.path.join(SW, "lib"), "-I", OUT, "-T", os.path.join(SW, "link.ld"),
                            "-o", elf, os.path.join(SW, "lib", "crt0.S"), os.path.join(SW, "lib", "lib.c"),
                            os.path.join(SW, name + ".c")]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode:
        print(r.stdout + r.stderr)
        raise RuntimeError(f"gcc failed on {name}")
    objdump = tool(gcc, "objdump")
    if os.path.exists(objdump) or shutil.which(objdump):
        with open(os.path.join(OUT, (out_name or name) + ".dis"), "w") as f:
            subprocess.run([objdump, "-d", elf], stdout=f)
    return elf


def programs():
    return sorted(os.path.splitext(os.path.basename(p))[0] for p in glob.glob(os.path.join(SW, "*.c")))


def main():
    names = sys.argv[1:] or programs()
    gcc = find_gcc()
    print("gcc:", gcc)
    for n in names:
        print(" ", build(n, gcc))


if __name__ == "__main__":
    main()
