// first c program: print something, do a bit of math, exit 0

#include "soc.h"

int main(void)
{
    puts_("hello from rv32i\n");
    puts_("clock ");
    put_udec(SYS_CLK_HZ);
    puts_(" Hz\n");

    int32_t a = 12345, b = -678;
    puts_("12345 * -678 = ");
    put_dec(a * b);
    puts_("\n100000 / 7 = ");
    put_dec(100000 / 7);
    puts_(" rem ");
    put_dec(100000 % 7);
    puts_("\n");
    SYS_LED = 0x15;
    return 0;
}
