/* c programs live in the 64 KB block ram, stack at the top */
OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY
{
    ram (rwx) : ORIGIN = 0x00000000, LENGTH = 64K
}

SECTIONS
{
    .text : {
        *(.text.start)
        *(.text .text.*)
    } > ram
    .rodata : { *(.rodata .rodata.* .srodata .srodata.*) } > ram
    .data : { *(.data .data.* .sdata .sdata.*) } > ram
    .bss (NOLOAD) : {
        . = ALIGN(4);
        __bss_start = .;
        *(.bss .bss.* .sbss .sbss.* COMMON)
        . = ALIGN(4);
        __bss_end = .;
    } > ram
    __stack_top = ORIGIN(ram) + LENGTH(ram);
    __global_pointer$ = 0x800;
}
