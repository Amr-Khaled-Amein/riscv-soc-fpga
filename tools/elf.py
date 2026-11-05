"""
minimal elf32 little endian reader: loadable segments + symbol table
"""

import struct


def read(path):
    with open(path, "rb") as f:
        return f.read()


def load(path):
    """-> ([(address, bytes) per loadable segment, bss zeros included], {symbol: address})"""
    d = read(path)
    if d[:4] != b"\x7fELF" or d[4] != 1 or d[5] != 1:
        raise ValueError(f"{path}: not a 32 bit little endian elf")
    (e_type, e_machine, _, e_entry, e_phoff, e_shoff, _, _, e_phentsize, e_phnum,
     e_shentsize, e_shnum, e_shstrndx) = struct.unpack_from("<HHIIIIIHHHHHH", d, 16)
    if e_machine != 243:
        raise ValueError(f"{path}: not risc-v")

    segs = []
    for i in range(e_phnum):
        p_type, p_off, _, p_paddr, p_filesz, p_memsz, _, _ = struct.unpack_from("<IIIIIIII", d, e_phoff + i * e_phentsize)
        if p_type == 1 and p_memsz:
            segs.append((p_paddr, d[p_off:p_off + p_filesz], p_memsz))
    out = [(a, bytes(data) + bytes(m - len(data))) for a, data, m in segs]

    syms = {}
    for i in range(e_shnum):
        sh = struct.unpack_from("<IIIIIIIIII", d, e_shoff + i * e_shentsize)
        if sh[1] == 2:                      # SHT_SYMTAB
            strtab = struct.unpack_from("<IIIIIIIIII", d, e_shoff + sh[6] * e_shentsize)
            for j in range(sh[5] // 16):
                st_name, st_value, _, _, _, _ = struct.unpack_from("<IIIBBH", d, sh[4] + j * 16)
                if st_name:
                    s = d[strtab[4] + st_name:d.index(b"\0", strtab[4] + st_name)].decode()
                    syms[s] = st_value
    syms["_entry"] = e_entry
    return out, syms
