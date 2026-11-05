# every peripheral over axi4-lite: sys scratch (word / half / byte strobes), timer,
# uart status, a small fft run, sdram data. exits with 0 or the failed check

    li   x31, 1
    li   x10, 0x10003000    # sys
    li   x1, 0x11223344
    sw   x1, 12(x10)
    lw   x2, 12(x10)
    bne  x1, x2, fail
    li   x31, 2
    li   x1, 0xaa
    sb   x1, 13(x10)        # one byte lane
    li   x1, 0xbeef
    sh   x1, 14(x10)        # upper half
    lw   x2, 12(x10)
    li   x4, 0xbeefaa44
    bne  x2, x4, fail
    lbu  x2, 15(x10)        # byte read from io
    li   x4, 0xbe
    bne  x2, x4, fail
    lh   x2, 14(x10)
    li   x4, -16657         # 0xbeef sign extended
    bne  x2, x4, fail
    li   x31, 3
    lw   x2, 8(x10)         # clock frequency
    li   x4, 27000000
    bne  x2, x4, fail
    li   x31, 4
    li   x1, 0x1f
    sw   x1, 0(x10)         # leds
    lw   x2, 0(x10)
    bne  x1, x2, fail

# timer counts, and is readable back to back
    li   x31, 5
    li   x11, 0x10001000
    lw   x1, 0(x11)
    lw   x2, 0(x11)
    bgeu x1, x2, fail
    li   x31, 6
    li   x1, 0x12345678
    sw   x1, 8(x11)
    lw   x2, 8(x11)
    bne  x1, x2, fail

# uart: tx not full, rx empty
    li   x31, 7
    li   x12, 0x10000000
    lw   x1, 8(x12)
    andi x1, x1, 3
    bnez x1, fail
    lw   x1, 4(x12)
    bgez x1, fail           # bit 31 set = nothing there

# fft: impulse in -> flat spectrum of 32767 / 256 = 128 (rounded)
    li   x31, 8
    li   x13, 0x10002000
    li   x1, 0x7fff0000     # sample 0 = 32767 + 0j
    sw   x1, 0x400(x13)
    li   x2, 1
    li   x3, 256
zero:
    slli x4, x2, 2
    add  x4, x4, x13
    sw   x0, 0x400(x4)
    addi x2, x2, 1
    bne  x2, x3, zero
    li   x1, 1
    sw   x1, 0(x13)
poll:
    lw   x1, 4(x13)
    andi x1, x1, 2
    beqz x1, poll
    li   x31, 9
    lw   x1, 8(x13)
    li   x4, 1029           # clocks for one fft
    bne  x1, x4, fail
    li   x31, 10
    lw   x1, 0x400(x13)     # bin 0
    li   x4, 0x00800000
    bne  x1, x4, fail
    lw   x1, 0x7fc(x13)     # bin 255
    bne  x1, x4, fail

# second run: dc in (0.5 + 0.25j everywhere) -> everything in bin 0. the done flag
# has to go away on start, and the old bins must be gone
    li   x31, 15
    li   x1, 0x40002000
    li   x2, 0
dc:
    slli x4, x2, 2
    add  x4, x4, x13
    sw   x1, 0x400(x4)
    addi x2, x2, 1
    bne  x2, x3, dc
    li   x1, 1
    sw   x1, 0(x13)
    lw   x1, 4(x13)
    andi x1, x1, 2
    bnez x1, fail           # done is cleared by start
poll2:
    lw   x1, 4(x13)
    andi x1, x1, 2
    beqz x1, poll2
    li   x31, 16
    lw   x1, 0x400(x13)
    li   x4, 0x40002000     # fft / 256 of a constant = the constant in bin 0
    bne  x1, x4, fail
    lw   x1, 0x404(x13)
    bnez x1, fail
    lw   x1, 0x7fc(x13)
    bnez x1, fail

# sdram through axi: word, then bytes into it
    li   x31, 11
    li   x14, 0x80200000
    li   x1, 0xcafef00d
    sw   x1, 0(x14)
    sw   x0, 4(x14)
    lw   x2, 0(x14)
    bne  x1, x2, fail
    li   x31, 12
    li   x1, 0x5a
    sb   x1, 1(x14)
    lw   x2, 0(x14)
    li   x4, 0xcafe5a0d
    bne  x2, x4, fail
    lh   x2, 2(x14)
    li   x4, 0xffffcafe
    bne  x2, x4, fail
    lw   x2, 4(x14)
    bnez x2, fail

    li   a0, 0
    j    done
fail:
    mv   a0, x31
done:
    li   t0, 0x10003004
    sw   a0, 0(t0)
    j    .
