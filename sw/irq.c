// timer interrupt from c: a tick every 1 ms while main keeps busy, the leds count ticks

#include "soc.h"

#ifndef TICK
#define TICK 27000              // clocks per tick at 27 MHz (the sim uses less)
#endif

static volatile uint32_t ticks;

static void next_tick(void)
{
    uint32_t lo = MTCMP_LO + TICK;
    uint32_t hi = MTCMP_HI + (lo < TICK);   // carry
    MTCMP_HI = 0xffffffffu;                 // no early fire while the two halves change
    MTCMP_LO = lo;
    MTCMP_HI = hi;
}

uint32_t trap_handler(uint32_t cause, uint32_t epc)
{
    if (cause == 0x80000007u) {
        ticks++;
        SYS_LED = ticks;
        next_tick();
        return epc;
    }
    puts_("unexpected trap ");
    put_hex(cause, 8);
    puts_("\n");
    exit(100);
}

int main(void)
{
    MTCMP_HI = 0;
    MTCMP_LO = MTIME_LO;
    next_tick();
    __asm__ volatile ("csrs mie, %0" :: "r"(0x80));
    __asm__ volatile ("csrsi mstatus, 8");

    // busy work while the ticks come in
    uint32_t sum = 0, n = 0;
    while (ticks < 20) {
        sum += n ^ (n << 3);
        n++;
    }
    __asm__ volatile ("csrci mstatus, 8");

    puts_("20 ticks, main loop ran ");
    put_udec(n);
    puts_(" times, sum ");
    put_hex(sum, 8);
    puts_("\n");
    return 0;
}
