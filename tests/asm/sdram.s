# code in the sdram: jump there from block ram, run a loop, self modifying code
# with fence.i, call back into block ram. exits with 0 or the failed check

    li   x31, 1
    li   sp, 0x10000
    li   x1, 0x80000000
    # copy the routine below into sdram, one word at a time
    la   x2, sd_code
    la   x3, sd_end
copy:
    lw   x4, 0(x2)
    sw   x4, 0(x1)
    addi x2, x2, 4
    addi x1, x1, 4
    bne  x2, x3, copy
    fence.i
    li   x1, 0x80000000
    jalr ra, 0(x1)          # into sdram
    li   x31, 5
    li   x4, 55
    bne  a1, x4, fail       # 1 + .. + 10 done in sdram
    li   x31, 6
    li   x4, 0x3e8          # the patched instruction ran (addi a2, x0, 1000)
    bne  a2, x4, fail
    li   x31, 7
    li   x4, 1
    bne  a3, x4, fail       # call back into block ram worked
    li   a0, 0
    j    done
fail:
    mv   a0, x31
done:
    li   t0, 0x10003004
    sw   a0, 0(t0)
    j    .

bram_func:
    li   a3, 1
    ret

# position independent, it runs at 0x80000000
sd_code:
    li   a1, 0
    li   a4, 10
sd_loop:
    add  a1, a1, a4
    addi a4, a4, -1
    bnez a4, sd_loop
    # patch the instruction at sd_patch, then run it
    auipc a5, 0
    addi a5, a5, 24         # -> sd_patch
    li   a6, 0x3e800613     # addi a2, x0, 1000
    sw   a6, 0(a5)
    fence.i
sd_patch:
    addi a2, x0, 1          # gets replaced
    mv   s1, ra
    li   a7, bram_func      # absolute, la is pc relative and this code got moved
    jalr ra, 0(a7)
    mv   ra, s1
    ret
sd_end:
