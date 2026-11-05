# official compliance tests

`elfs/` are the RISC-V architectural certification tests from
[riscv-arch-test](https://github.com/riscv-non-isa/riscv-arch-test) 4.1.0 (the ACT4
framework), built for this soc:

- `I/`        39 tests, the whole rv32i base instruction set
- `Zicsr/`    6 tests, csrrw / csrrs / csrrc and the immediate forms
- `Zifencei/` 1 test, fence.i with self modifying code

Each elf checks itself. The expected values were computed by the Sail RISC-V
reference model (0.13.1) when the tests were built and are compiled into the elf.
A test prints `RVCP-SUMMARY: TEST PASSED` on the uart and writes 1 to the exit
register, or prints the first failing case and writes 3.

`config/` describes this cpu to the framework: which extensions, how traps behave
(mtval contents, misaligned accesses trap, direct mtvec only), the memory map for
Sail, and `rvmodel_macros.h` with how to print and how to stop. The tests are
linked at 0x8000_0000 (sdram), because the biggest one (I-jal, it jumps up to
128 KB away) is 210 KB and doesn't fit in the 64 KB block ram.

`build.sh` rebuilds them (linux / wsl, gcc 15.2 + sail 0.13.1). The tests are
Apache-2.0, from the riscv-arch-test repo.
