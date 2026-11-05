// 256 point fft: the same fixed point algorithm in software on the cpu, and on the
// fft accelerator over axi. checks both give the same bits and times them.
//
// software = tools/fft_model.py exactly: radix-2 dit, bit reversed load, 8 stages
// of 128 butterflies in place, round to nearest, 1/2 per stage, saturate.
// the twiddles (twiddle.h) come out of the same generator as the hardware rom.
//
// results go into res[] so the host can read them back and check them against
// the python model too.

#include "soc.h"
#include "twiddle.h"

#define N    256
#define LOGN 8
#ifndef NSIG
#define NSIG 6                  // the simulation regression builds it with fewer
#endif

typedef struct {
    int16_t  in_re[N], in_im[N];
    int16_t  sw_re[N], sw_im[N];
    int16_t  hw_re[N], hw_im[N];
    uint32_t sw_cycles;         // software fft
    uint32_t hw_cycles;         // accelerator, from the cpu: write samples, run, read bins
    uint32_t fft_cycles;        // accelerator busy time (its own counter)
    uint32_t flags;             // bit 0 sw clipped, bit 1 hw clipped
} result_t;

result_t res[NSIG];
uint32_t res_count = NSIG;

// ---------------- software fft ----------------

static int16_t sat16(int32_t v, int *hit)
{
    if (v > 32767) { *hit = 1; return 32767; }
    if (v < -32768) { *hit = 1; return -32768; }
    return v;
}

// (a * 2^15 +- t + 2^15) >> 16, a sum that needs more than 32 bits
static int16_t bfly_out(int16_t a, int32_t t, int *hit)
{
    int64_t v = ((int64_t)a << 15) + t + 32768;
    return sat16((int32_t)(v >> 16), hit);
}

static int fft_sw(const int16_t *in_re, const int16_t *in_im, int16_t *xr, int16_t *xi)
{
    int hit = 0;
    for (int k = 0; k < N; k++) {
        int r = 0;
        for (int b = 0; b < LOGN; b++)
            r |= ((k >> b) & 1) << (LOGN - 1 - b);
        xr[r] = in_re[k];
        xi[r] = in_im[k];
    }
    for (int st = 0; st < LOGN; st++) {
        int span = 1 << st;
        for (int bf = 0; bf < N / 2; bf++) {
            int pos = bf & (span - 1);
            int a = ((bf >> st) << (st + 1)) | pos;
            int b = a + span;
            int k = pos << (LOGN - 1 - st);
            int32_t c = tw_cos[k], s = tw_sin[k];
            int32_t br = xr[b], bi = xi[b];
            int32_t tr = br * c + bi * s;           // b * (c - js)
            int32_t ti = bi * c - br * s;
            int16_t ar = xr[a], ai = xi[a];
            xr[a] = bfly_out(ar, tr, &hit);
            xi[a] = bfly_out(ai, ti, &hit);
            xr[b] = bfly_out(ar, -tr, &hit);
            xi[b] = bfly_out(ai, -ti, &hit);
        }
    }
    return hit;
}

// ---------------- accelerator ----------------

static int fft_hw(const int16_t *in_re, const int16_t *in_im, int16_t *xr, int16_t *xi)
{
    for (int k = 0; k < N; k++)
        FFT_DATA[k] = ((uint32_t)(uint16_t)in_re[k] << 16) | (uint16_t)in_im[k];
    FFT_CTRL = 1;
    while (!(FFT_STAT & 2))
        ;
    for (int k = 0; k < N; k++) {
        uint32_t w = FFT_DATA[k];
        xr[k] = w >> 16;
        xi[k] = w;
    }
    return (FFT_STAT >> 2) & 1;
}

// ---------------- test signals ----------------

// cos / sin of 2 pi m / N out of the twiddle table
static int32_t cosm(int m) { m &= N - 1; return m < N / 2 ? tw_cos[m] : -tw_cos[m - N / 2]; }
static int32_t sinm(int m) { m &= N - 1; return m < N / 2 ? tw_sin[m] : -tw_sin[m - N / 2]; }

static uint32_t lcg = 1;
static int32_t rnd16(void)
{
    lcg = lcg * 1103515245u + 12345u;
    return (int32_t)(lcg >> 16) - 32768;
}

// fs_square first: one period of a square wave on the corners (|x| = 1.41), it has to clip
static const char *names[6] = {"fs_square", "tone_bin10", "two_tones", "noise", "impulse", "dc"};

static void make(int sig, int16_t *re, int16_t *im)
{
    for (int n = 0; n < N; n++) {
        int32_t r = 0, i = 0;
        switch (sig) {
        case 0: r = cosm(n) >= 0 ? 32767 : -32768; i = sinm(n) >= 0 ? 32767 : -32768; break;
        case 1: r = (cosm(10 * n) * 29491) >> 15; i = (sinm(10 * n) * 29491) >> 15; break;
        case 2: r = ((cosm(17 * n) + cosm(-60 * n)) * 14745) >> 15;
                i = ((sinm(17 * n) + sinm(-60 * n)) * 14745) >> 15; break;
        case 3: r = rnd16() >> 1; i = rnd16() >> 1; break;
        case 4: r = (n == 0) ? 32767 : 0; break;
        case 5: r = 29491; i = -16384; break;
        }
        re[n] = r;
        im[n] = i;
    }
}

int main(void)
{
    int all_same = 1;
    uint32_t sw_tot = 0, hw_tot = 0;

    puts_("256 point fft, software on the cpu vs the accelerator\n");
    for (int s = 0; s < NSIG; s++) {
        result_t *r = &res[s];
        make(s, r->in_re, r->in_im);

        uint32_t t0 = rdcycle();
        int sw_sat = fft_sw(r->in_re, r->in_im, r->sw_re, r->sw_im);
        uint32_t t1 = rdcycle();
        int hw_sat = fft_hw(r->in_re, r->in_im, r->hw_re, r->hw_im);
        uint32_t t2 = rdcycle();

        r->sw_cycles = t1 - t0;
        r->hw_cycles = t2 - t1;
        r->fft_cycles = FFT_CYCLES;
        r->flags = sw_sat | (hw_sat << 1);

        int same = (sw_sat == hw_sat);
        for (int k = 0; k < N; k++)
            if (r->sw_re[k] != r->hw_re[k] || r->sw_im[k] != r->hw_im[k])
                same = 0;
        all_same &= same;
        sw_tot += r->sw_cycles;
        hw_tot += r->hw_cycles;

        puts_(names[s]);
        puts_(": sw ");
        put_udec(r->sw_cycles);
        puts_(" cycles, hw ");
        put_udec(r->hw_cycles);
        puts_(" (core ");
        put_udec(r->fft_cycles);
        puts_("), ");
        puts_(same ? "same bits" : "DIFFERENT");
        if (sw_sat)
            puts_(", clipped");
        puts_("\n");
    }
    puts_("speedup ");
    put_udec(sw_tot / hw_tot);
    putc_('.');
    put_udec((sw_tot * 10 / hw_tot) % 10);
    puts_("x including the bus transfers\n");
    puts_(all_same ? "all bit exact\n" : "MISMATCH\n");
    return all_same ? 0 : 1;
}
