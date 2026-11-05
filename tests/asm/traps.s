# traps: every exception the core can take, with mcause / mepc / mtval checked,
# then a timer interrupt and mret. exits with 0 or the number of the failed check

    la   t0, handler
    csrw mtvec, t0
    li   x31, 0
    li   x30, 0             # trap counter (registers aren't cleared by reset on the board)

# each check: x20 = expected mcause, x21 = expected mtval, then the trapping
# instruction at label tN. the handler checks mepc == x22 and skips it

    li   x31, 1
    li   x20, 2
    la   x22, t1
    lw   x21, 0(x22)        # mtval = the instruction itself
t1: .word 0xffffffff        # illegal
    li   x31, 2
    li   x20, 11
    li   x21, 0
    la   x22, t2
t2: ecall
    li   x31, 3
    li   x20, 3
    la   x21, t3
    la   x22, t3
t3: ebreak
    li   x31, 4
    li   x20, 4
    li   x21, 0x8001
    la   x22, t4
    li   x1, 0x8000
t4: lh   x2, 1(x1)          # misaligned load
    li   x31, 5
    li   x20, 6
    li   x21, 0x8002
    la   x22, t5
t5: sw   x2, 2(x1)          # misaligned store
    li   x31, 6
    li   x20, 5
    li   x21, 0x20000000
    la   x22, t6
    li   x1, 0x20000000
t6: lw   x2, 0(x1)          # load from nowhere
    li   x31, 7
    li   x20, 7
    li   x21, 0x10004000
    la   x22, t7
    li   x1, 0x10004000
t7: sw   x2, 0(x1)          # store into the gap after the peripherals
    li   x31, 8
    li   x20, 0
    la   x21, t8
    addi x21, x21, 6
    la   x22, t8
t8: jal  x0, t8 + 6         # misaligned jump target
    li   x31, 9
    li   x20, 2
    li   x21, 0xf1101073
    la   x22, t9
t9: csrw mvendorid, x0      # write to a read only csr
    li   x31, 10
    li   x20, 2
    li   x21, 0x7c002073
    la   x22, t10
t10: csrr x0, 0x7c0        # csr that doesn't exist

# 11: the trapped instructions didn't write anything
    li   x31, 11
    li   x5, 123
    li   x20, 2
    la   x22, t11
    lw   x21, 0(x22)
t11: .word 0x0000b283       # ld x5 (illegal on rv32), must not touch x5
    li   x4, 123
    bne  x5, x4, fail
    li   x4, 11
    bne  x30, x4, fail      # 11 traps so far, counted by the handler

# 12: mstatus.MIE -> MPIE on a trap, back on mret
    li   x31, 12
    csrsi mstatus, 8
    li   x20, 11
    li   x21, 0
    la   x22, t12
t12: ecall
    csrr x1, mstatus
    andi x1, x1, 0x88
    li   x4, 0x88           # MIE back on, MPIE 1
    bne  x1, x4, fail
    csrci mstatus, 8

# 13: timer interrupt. mtimecmp = now + 100, wait in a loop
    li   x31, 13
    li   x20, -1            # handler: don't check, it's an interrupt
    li   x10, 0x10001000
    lw   x1, 0(x10)
    addi x1, x1, 100
    sw   x0, 12(x10)
    sw   x1, 8(x10)
    li   x1, 0x80
    csrs mie, x1
    li   x29, 0
    csrsi mstatus, 8
    li   x2, 2000
wait13:
    bnez x29, got13
    addi x2, x2, -1
    bnez x2, wait13
    j    fail
got13:
    csrci mstatus, 8
    li   x4, 0x80000007
    bne  x28, x4, fail      # mcause seen by the handler
    csrr x1, mip
    li   x4, 0
    bne  x1, x4, fail       # handler pushed mtimecmp out, so it's low again

# 14: masked interrupt does nothing
    li   x31, 14
    li   x29, 0
    lw   x1, 0(x10)
    sw   x0, 12(x10)
    sw   x1, 8(x10)         # pending right away
    csrr x2, mip
    beqz x2, fail
    nop
    nop
    bnez x29, fail          # MIE is off
    li   x1, -1
    sw   x1, 8(x10)
    sw   x1, 12(x10)

    li   a0, 0
    j    done
fail:
    mv   a0, x31
done:
    li   t0, 0x10003004
    sw   a0, 0(t0)
    j    .

    .align 2
handler:
    csrr x26, mcause
    csrr x27, mepc
    bltz x26, irq
    addi x30, x30, 1
    bne  x26, x20, hfail
    bne  x27, x22, hfail
    csrr x25, mtval
    bne  x25, x21, hfail
    addi x27, x27, 4
    csrw mepc, x27
    mret
irq:
    mv   x28, x26
    li   x29, 1
    li   x1, -1
    sw   x1, 12(x10)        # mtimecmp far away
    mret
hfail:
    mv   a0, x31
    addi a0, a0, 100        # 100 + check number: the handler saw something wrong
    j    done
