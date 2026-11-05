// tb_top - the whole design (top.v) through its uart pins, plus the sdram model
//
// the host side is a script made by tools/run_tests.py (host.txt), one step per line:
//   S <hex bytes>   send these bytes on the serial line
//   N <n>           wait until n more bytes came back
//   E               wait until an end frame (FF FF 'E' + 9 bytes) came back
//   D <clocks>      do nothing for a while
// everything the fpga sends ends up in uart.out (as hex), run_tests.py checks it.
// the uart runs at 27 MHz / 8 here so it doesn't take forever.

`timescale 1ns/1ps

module tb_top;
    localparam CPB = 8;

    logic clk = 1'b0;
    always #18.5 clk = ~clk;

    logic rxd = 1'b1;               // into the fpga
    wire  txd;
    wire [5:0] led;
    wire        sd_clk, sd_cke, sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n;
    wire [10:0] sd_addr;
    wire [1:0]  sd_ba;
    wire [3:0]  sd_dqm;
    wire [31:0] sd_dq;

    top #(.CLKS_PER_BIT(CPB), .TIMEOUT(3000), .SD_INIT(50)) dut (
        .clk(clk), .uart_rxd(rxd), .uart_txd(txd), .led(led),
        .O_sdram_clk(sd_clk), .O_sdram_cke(sd_cke), .O_sdram_cs_n(sd_cs_n), .O_sdram_cas_n(sd_cas_n),
        .O_sdram_ras_n(sd_ras_n), .O_sdram_wen_n(sd_we_n), .O_sdram_dqm(sd_dqm), .O_sdram_addr(sd_addr),
        .O_sdram_ba(sd_ba), .IO_sdram_dq(sd_dq)
    );

    sdram_model u_sdram (.clk(sd_clk), .cke(sd_cke), .cs_n(sd_cs_n), .ras_n(sd_ras_n), .cas_n(sd_cas_n),
        .we_n(sd_we_n), .addr(sd_addr), .ba(sd_ba), .dqm(sd_dqm), .dq(sd_dq));

    // ---------------- serial in / out ----------------
    task send_byte(input [7:0] b);
        rxd = 1'b0;
        repeat (CPB) @(posedge clk);
        for (int i = 0; i < 8; i++) begin
            rxd = b[i];
            repeat (CPB) @(posedge clk);
        end
        rxd = 1'b1;
        repeat (CPB) @(posedge clk);
    endtask

    int nrx = 0;
    logic [7:0] last [0:11];
    int fo;
    initial fo = $fopen("uart.out", "w");

    // receiver: wait for the start bit, sample in the middle of each bit
    always begin
        logic [7:0] b;
        @(negedge txd);
        repeat (CPB / 2) @(posedge clk);
        for (int i = 0; i < 8; i++) begin
            repeat (CPB) @(posedge clk);
            b[i] = txd;
        end
        repeat (CPB) @(posedge clk);
        $fdisplay(fo, "%02x", b);
        for (int i = 0; i < 11; i++) last[i] = last[i + 1];
        last[11] = b;
        nrx++;
    end

    wire end_frame = (last[0] == 8'hff) && (last[1] == 8'hff) && (last[2] == "E");

    // ---------------- script ----------------
    int fs, r, n, want, t0;
    logic [7:0] byt;
    byte cmd;
    int errors = 0;

    initial begin
        fs = $fopen("host.txt", "r");
        if (!fs) begin
            $display("FAIL: no host.txt");
            $finish;
        end
        repeat (400) @(posedge clk);        // power on reset + sdram init
        while ($fscanf(fs, " %c", cmd) == 1) begin
            case (cmd)
                "S": begin
                    r = $fscanf(fs, "%d", n);
                    for (int i = 0; i < n; i++) begin
                        r = $fscanf(fs, "%h", byt);
                        send_byte(byt);
                    end
                end
                "N": begin
                    r = $fscanf(fs, "%d", n);
                    want = nrx + n;
                    t0 = $time;
                    while (nrx < want && $time - t0 < 200_000_000) @(posedge clk);
                    if (nrx < want) begin
                        $display("FAIL: waited for %0d bytes, got %0d", n, n - (want - nrx));
                        errors++;
                    end
                end
                "E": begin
                    t0 = $time;
                    // a fresh frame: clear the window first
                    for (int i = 0; i < 12; i++) last[i] = 8'h00;
                    while (!end_frame && $time - t0 < 400_000_000) @(posedge clk);
                    if (!end_frame) begin
                        $display("FAIL: no end frame");
                        errors++;
                    end
                end
                "D": begin
                    r = $fscanf(fs, "%d", n);
                    repeat (n) @(posedge clk);
                end
                default: ;
            endcase
        end
        repeat (200) @(posedge clk);
        $fclose(fo);
        if (errors == 0 && u_sdram.errors == 0)
            $display("DONE: %0d bytes back", nrx);
        else
            $display("FAIL: %0d script errors, %0d sdram errors", errors, u_sdram.errors);
        $finish;
    end
endmodule
