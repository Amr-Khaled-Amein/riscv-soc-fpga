// uart printing, and the multiply / divide helpers gcc calls on rv32i (no M extension)

#include "soc.h"

void putc_(char c)
{
    while (UART_TX & 0x80000000u)       // fifo full
        ;
    UART_TX = (uint8_t)c;
}

void puts_(const char *s)
{
    while (*s) {
        if (*s == '\n')
            putc_('\r');
        putc_(*s++);
    }
}

void put_udec(uint32_t v)
{
    char buf[12];
    int i = 0;
    do {
        buf[i++] = '0' + v % 10;
        v /= 10;
    } while (v);
    while (i)
        putc_(buf[--i]);
}

void put_dec(int32_t v)
{
    if (v < 0) {
        putc_('-');
        put_udec(-(uint32_t)v);
    } else
        put_udec(v);
}

void put_hex(uint32_t v, int digits)
{
    for (int i = digits - 1; i >= 0; i--)
        putc_("0123456789abcdef"[(v >> (4 * i)) & 15]);
}

// ---- what libgcc would give us, shift and add / subtract ----

uint32_t __mulsi3(uint32_t a, uint32_t b)
{
    uint32_t r = 0;
    while (a) {
        if (a & 1)
            r += b;
        a >>= 1;
        b <<= 1;
    }
    return r;
}

static uint32_t udivmod(uint32_t n, uint32_t d, uint32_t *rem)
{
    uint32_t q = 0, r = 0;
    if (d == 0) {
        *rem = n;
        return 0xffffffffu;
    }
    for (int i = 31; i >= 0; i--) {
        r = (r << 1) | ((n >> i) & 1);
        if (r >= d) {
            r -= d;
            q |= 1u << i;
        }
    }
    *rem = r;
    return q;
}

uint32_t __udivsi3(uint32_t n, uint32_t d) { uint32_t r; return udivmod(n, d, &r); }
uint32_t __umodsi3(uint32_t n, uint32_t d) { uint32_t r; udivmod(n, d, &r); return r; }

int32_t __divsi3(int32_t n, int32_t d)
{
    uint32_t r, q = udivmod(n < 0 ? -(uint32_t)n : n, d < 0 ? -(uint32_t)d : d, &r);
    return ((n < 0) != (d < 0)) ? -(int32_t)q : (int32_t)q;
}

int32_t __modsi3(int32_t n, int32_t d)
{
    uint32_t r;
    udivmod(n < 0 ? -(uint32_t)n : n, d < 0 ? -(uint32_t)d : d, &r);
    return n < 0 ? -(int32_t)r : (int32_t)r;
}

// gcc can turn loops into these
void *memset(void *p, int c, unsigned n)
{
    uint8_t *d = p;
    while (n--)
        *d++ = c;
    return p;
}

void *memcpy(void *dst, const void *src, unsigned n)
{
    uint8_t *d = dst;
    const uint8_t *s = src;
    while (n--)
        *d++ = *s++;
    return dst;
}

// default trap handler: print what happened and stop
uint32_t __attribute__((weak)) trap_handler(uint32_t cause, uint32_t epc)
{
    puts_("\ntrap: mcause ");
    put_hex(cause, 8);
    puts_(" mepc ");
    put_hex(epc, 8);
    puts_("\n");
    exit(100);
}
