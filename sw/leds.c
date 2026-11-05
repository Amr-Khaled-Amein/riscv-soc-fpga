// led demo for the photo: a dot bounces over led 0-4 on the timer interrupt
// (10 times a second) until a byte comes in on the uart

#include "soc.h"

#define STEP 2700000            // 100 ms at 27 MHz

static volatile uint32_t pos, dir = 1;

uint32_t trap_handler(uint32_t cause, uint32_t epc)
{
    if (cause == 0x80000007u) {
        if (pos == 4) dir = -1;
        if (pos == 0) dir = 1;
        pos += dir;
        SYS_LED = 1u << pos;
        uint32_t lo = MTCMP_LO + STEP;
        uint32_t hi = MTCMP_HI + (lo < STEP);
        MTCMP_HI = 0xffffffffu;
        MTCMP_LO = lo;
        MTCMP_HI = hi;
        return epc;
    }
    exit(100);
}

int main(void)
{
    puts_("leds running, send any key to stop\n");
    SYS_LED = 1;
    MTCMP_HI = 0;
    MTCMP_LO = MTIME_LO + STEP;
    __asm__ volatile ("csrs mie, %0" :: "r"(0x80));
    __asm__ volatile ("csrsi mstatus, 8");
    while (UART_RX & 0x80000000u)       // nothing there yet
        ;
    puts_("stopped\n");
    return 0;
}
