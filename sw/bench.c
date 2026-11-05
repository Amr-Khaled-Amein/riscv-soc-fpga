// small integer benchmark: bubble sort, crc32, primes. prints cycles, instructions, cpi

#include "soc.h"

#define NSORT 200

static int32_t arr[NSORT];
uint32_t bench_out[4];          // the host reads these back

static uint32_t lcg = 12345;
static uint32_t rnd(void)
{
    lcg = lcg * 1103515245u + 12345u;
    return lcg >> 8;
}

static void sort(int32_t *a, int n)
{
    for (int i = 0; i < n - 1; i++)
        for (int j = 0; j < n - 1 - i; j++)
            if (a[j] > a[j + 1]) {
                int32_t t = a[j];
                a[j] = a[j + 1];
                a[j + 1] = t;
            }
}

static uint32_t crc32(const uint8_t *p, int n)
{
    uint32_t c = 0xffffffffu;
    while (n--) {
        c ^= *p++;
        for (int k = 0; k < 8; k++)
            c = (c >> 1) ^ (0xedb88320u & -(c & 1));
    }
    return ~c;
}

static int primes(int n)
{
    // sieve, no multiply needed
    static uint8_t comp[2000];
    int cnt = 0;
    for (int i = 2; i < n; i++) {
        if (comp[i])
            continue;
        cnt++;
        for (int j = i + i; j < n; j += i)
            comp[j] = 1;
    }
    return cnt;
}

static void report(const char *name, uint32_t cyc, uint32_t ins)
{
    puts_(name);
    puts_(": ");
    put_udec(cyc);
    puts_(" cycles, ");
    put_udec(ins);
    puts_(" instructions, cpi ");
    // cpi with 2 decimals without floats
    uint32_t c100 = (cyc * 100 + ins / 2) / ins;
    put_udec(c100 / 100);
    putc_('.');
    putc_('0' + (c100 / 10) % 10);
    putc_('0' + c100 % 10);
    puts_("\n");
}

int main(void)
{
    for (int i = 0; i < NSORT; i++)
        arr[i] = (int32_t)rnd() - 0x400000;

    uint32_t c0 = rdcycle(), i0 = rdinstret();
    sort(arr, NSORT);
    uint32_t c1 = rdcycle(), i1 = rdinstret();
    uint32_t crc = crc32((const uint8_t *)arr, sizeof(arr));
    uint32_t c2 = rdcycle(), i2 = rdinstret();
    int np = primes(2000);
    uint32_t c3 = rdcycle(), i3 = rdinstret();

    int ok = 1;
    for (int i = 0; i < NSORT - 1; i++)
        if (arr[i] > arr[i + 1])
            ok = 0;

    report("sort  ", c1 - c0, i1 - i0);
    report("crc32 ", c2 - c1, i2 - i1);
    report("primes", c3 - c2, i3 - i2);
    report("total ", c3 - c0, i3 - i0);
    puts_("crc ");
    put_hex(crc, 8);
    puts_(", primes below 2000: ");
    put_dec(np);
    puts_(ok ? ", sorted\n" : ", NOT sorted\n");

    bench_out[0] = c3 - c0;
    bench_out[1] = i3 - i0;
    bench_out[2] = crc;
    bench_out[3] = np;
    return ok ? 0 : 1;
}
