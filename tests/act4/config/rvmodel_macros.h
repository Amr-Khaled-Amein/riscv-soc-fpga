# rvmodel_macros.h for the rv32i soc in this repo
#   exit register  0x10003004  (1 = pass, 3 = fail)
#   uart tx        0x10000000  (bit 31 of a read = fifo full)

#ifndef _RVMODEL_MACROS_H
#define _RVMODEL_MACROS_H

#define RVMODEL_DATA_SECTION

#define STANDARD_SM_SUPPORTED

// loads / stores here fault
#define RVMODEL_ACCESS_FAULT_ADDRESS 0x20000000

#define RVMODEL_HALT_PASS  \
  li x1, 1                ;\
  li t0, 0x10003004       ;\
  sw x1, 0(t0)            ;\
  self_loop_pass:         ;\
    j self_loop_pass      ;

#define RVMODEL_HALT_FAIL  \
  li x1, 3                ;\
  li t0, 0x10003004       ;\
  sw x1, 0(t0)            ;\
  self_loop_fail:         ;\
    j self_loop_fail      ;

// print a 0 terminated string, wait while the uart fifo is full
#define RVMODEL_IO_WRITE_STR(_R1, _R2, _R3, _STR_PTR) \
1:                           ;                        \
  lbu  _R1, 0(_STR_PTR)      ;                        \
  beqz _R1, 3f               ;                        \
  li   _R2, 0x10000000       ;                        \
2:                           ;                        \
  lw   _R3, 0(_R2)           ;                        \
  bltz _R3, 2b               ;                        \
  sw   _R1, 0(_R2)           ;                        \
  addi _STR_PTR, _STR_PTR, 1 ;                        \
  j 1b                       ;                        \
3:

#define RVMODEL_INTERRUPT_LATENCY 10
#define RVMODEL_MAX_CYCLES_PER_TIMER_TICK 1
#define RVMODEL_TIMER_INT_SOON_DELAY 100

#define RVMODEL_MTIME_ADDRESS     0x10001000
#define RVMODEL_MTIMECMP_ADDRESS  0x10001008

// no software or external interrupt lines on this soc
#define RVMODEL_SET_MEXT_INT(_R1, _R2)
#define RVMODEL_CLR_MEXT_INT(_R1, _R2)
#define RVMODEL_SET_MSW_INT(_R1, _R2)
#define RVMODEL_CLR_MSW_INT(_R1, _R2)

// no s-mode either
#define RVMODEL_SET_SEXT_INT(_R1, _R2)
#define RVMODEL_CLR_SEXT_INT(_R1, _R2)
#define RVMODEL_SET_SSW_INT(_R1, _R2)
#define RVMODEL_CLR_SSW_INT(_R1, _R2)

#endif
