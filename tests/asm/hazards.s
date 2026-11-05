# pipeline hazards: every forwarding path, load-use, branches that go both ways,
# jal / jalr. exits with 0, or the number of the check that failed (in x31)

    li   x31, 0
# 1: EX/MEM forward, back to back
    li   x31, 1
    li   x1, 5
    addi x2, x1, 3          # x1 from MEM
    add  x3, x2, x2         # x2 from MEM, both operands
    li   x4, 16
    bne  x3, x4, fail
# 2: MEM/WB forward (one instruction in between)
    li   x31, 2
    li   x1, 7
    nop
    add  x2, x1, x1
    li   x4, 14
    bne  x2, x4, fail
# 3: through the register file (two in between)
    li   x31, 3
    li   x1, 9
    nop
    nop
    add  x2, x1, x0
    li   x4, 9
    bne  x2, x4, fail
# 4: newest value wins when two in flight write the same register
    li   x31, 4
    li   x1, 1
    li   x1, 2
    add  x2, x1, x0
    li   x4, 2
    bne  x2, x4, fail
# 5: load-use, then load used by a store and by a branch
    li   x31, 5
    li   x10, 0x8000
    li   x1, 0x1234
    sw   x1, 0(x10)
    lw   x2, 0(x10)
    addi x3, x2, 1          # stall
    li   x4, 0x1235
    bne  x3, x4, fail
    lw   x5, 0(x10)
    sw   x5, 4(x10)         # store data from the load
    lw   x6, 4(x10)
    bne  x6, x1, fail       # branch right after a load
# 6: load into x0 must not forward anything
    li   x31, 6
    li   x7, 77
    lw   x0, 0(x10)
    add  x8, x0, x7
    bne  x8, x7, fail
# 7: backward branch taken (predicted), not taken at the end (mispredict)
    li   x31, 7
    li   x1, 10
    li   x2, 0
loop1:
    addi x2, x2, 2
    addi x1, x1, -1
    bnez x1, loop1
    li   x4, 20
    bne  x2, x4, fail
# 8: forward branch taken (mispredicted as not taken), skips two
    li   x31, 8
    li   x1, 1
    beq  x1, x1, skip8
    li   x1, 2
    li   x1, 3
skip8:
    li   x4, 1
    bne  x1, x4, fail
# 9: branch that depends on the instruction right before it
    li   x31, 9
    li   x1, 3
    addi x1, x1, -3
    bnez x1, fail
    beqz x1, ok9
    j    fail
ok9:
# 10: jal / jalr, return address forwarded straight away, call in a loop
    li   x31, 10
    li   x5, 0
    li   x6, 4
loop10:
    jal  ra, inc5
    addi x6, x6, -1
    bnez x6, loop10
    li   x4, 4
    bne  x5, x4, fail
# 11: jalr with an odd offset (bit 0 is dropped) and rd = rs1
    li   x31, 11
    la   x1, t11
    jalr x1, 1(x1)
    j    fail
t11:
    la   x2, t11
    beq  x1, x2, fail       # x1 = return address, not the target
# 12: lui / auipc
    li   x31, 12
    lui  x1, 0xabcde
    li   x2, 0xabcde000
    bne  x1, x2, fail
    auipc x3, 0
    la   x4, here12
here12:
    addi x4, x4, -12        # la is auipc + addi, here12 is 3 instructions on
    bne  x3, x4, fail
# 13: sub-word loads and stores, sign extension
    li   x31, 13
    li   x1, 0x80ff7f01
    sw   x1, 8(x10)
    lb   x2, 11(x10)
    li   x4, -128
    bne  x2, x4, fail
    lbu  x2, 10(x10)
    li   x4, 0xff
    bne  x2, x4, fail
    lh   x2, 10(x10)
    li   x4, -32513         # 0x80ff
    bne  x2, x4, fail
    lhu  x2, 8(x10)
    li   x4, 0x7f01
    bne  x2, x4, fail
    sb   x0, 9(x10)
    sh   x1, 10(x10)
    lw   x2, 8(x10)
    li   x4, 0x7f010001
    bne  x2, x4, fail

    li   a0, 0
    j    done
fail:
    mv   a0, x31
done:
    li   t0, 0x10003004
    sw   a0, 0(t0)
    j    .
inc5:
    addi x5, x5, 1
    ret
