// registers of the soc + a few small helpers
#ifndef SOC_H
#define SOC_H

#include <stdint.h>

#define REG(a) (*(volatile uint32_t *)(a))

#define UART_TX    REG(0x10000000)
#define UART_RX    REG(0x10000004)
#define UART_STAT  REG(0x10000008)

#define MTIME_LO   REG(0x10001000)
#define MTIME_HI   REG(0x10001004)
#define MTCMP_LO   REG(0x10001008)
#define MTCMP_HI   REG(0x1000100c)

#define FFT_CTRL   REG(0x10002000)
#define FFT_STAT   REG(0x10002004)
#define FFT_CYCLES REG(0x10002008)
#define FFT_DATA   ((volatile uint32_t *)0x10002400)

#define SYS_LED    REG(0x10003000)
#define SYS_EXIT   REG(0x10003004)
#define SYS_CLK_HZ REG(0x10003008)

static inline uint32_t rdcycle(void)
{
    uint32_t c;
    __asm__ volatile ("csrr %0, mcycle" : "=r"(c));
    return c;
}

static inline uint32_t rdinstret(void)
{
    uint32_t c;
    __asm__ volatile ("csrr %0, minstret" : "=r"(c));
    return c;
}

void putc_(char c);
void puts_(const char *s);
void put_dec(int32_t v);
void put_udec(uint32_t v);
void put_hex(uint32_t v, int digits);
void exit(int code) __attribute__((noreturn));

#endif
