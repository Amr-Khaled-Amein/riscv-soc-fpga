// tb_soc - runs one program on the soc (core + ram + axi bus + peripherals)
//
// the program is put straight into the ram, the uart tx bytes are caught at the
// peripheral (no slow serial). stops when the program writes the exit register.
//
//   +hex=prog.hex   block ram image, one 32 bit word per line from address 0 (default prog.hex)
//   +sdhex=f.hex    sdram image, same format, from 0x8000_0000
//   +pc=80000000    where to start (hex, default 0)
//   +trace          write trace.txt, one line per finished instruction, for rv_sim.check_trace
//   +max=N          give up after N clocks (default 2,000,000)
//   +vcd            dump tb_soc.vcd
//
// writes uart.out (what the program printed) and result.txt (exit code, clocks,
// instructions, registers)

`timescale 1ns/1ps

module tb_soc;
    parameter RAM_AW = 14;

    logic clk = 1'b0;
    logic rst = 1'b1;
    always #18.5 clk = ~clk;

    wire [7:0]  tx_data;
    wire        tx_valid, tx_idle, exit_valid;
    wire [31:0] exit_code, ld_rdata;
    wire [4:0]  led;

    logic [31:0] reset_pc = 32'd0;
    wire         ld_ack;
    wire         sd_clk, sd_cke, sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n;
    wire [10:0]  sd_addr;
    wire [1:0]   sd_ba;
    wire [3:0]   sd_dqm;
    wire [31:0]  sd_dq;

    soc #(.RAM_AW(RAM_AW), .SD_INIT(20)) dut (
        .clk(clk), .rst(rst), .cpu_rst(rst), .io_rst(rst), .reset_pc(reset_pc),
        .ld_req(1'b0), .ld_we(1'b0), .ld_addr(32'd0), .ld_wdata(8'd0), .ld_ack(ld_ack), .ld_rdata(ld_rdata),
        .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(1'b1),
        .rx_data(8'd0), .rx_valid(1'b0), .tx_idle(tx_idle),
        .led(led), .exit_valid(exit_valid), .exit_code(exit_code),
        .sd_clk(sd_clk), .sd_cke(sd_cke), .sd_cs_n(sd_cs_n), .sd_ras_n(sd_ras_n), .sd_cas_n(sd_cas_n),
        .sd_we_n(sd_we_n), .sd_addr(sd_addr), .sd_ba(sd_ba), .sd_dqm(sd_dqm), .sd_dq(sd_dq)
    );

    sdram_model u_sdram (.clk(sd_clk), .cke(sd_cke), .cs_n(sd_cs_n), .ras_n(sd_ras_n), .cas_n(sd_cas_n),
        .we_n(sd_we_n), .addr(sd_addr), .ba(sd_ba), .dqm(sd_dqm), .dq(sd_dq));

    logic [31:0] img [0:(1<<RAM_AW)-1];
    string hexfile, sdfile;
    int    maxcyc, cyc, k, ftr, fu, fres;
    bit    tracing, got_exit;

    // ---------------- commit trace ----------------
    wire freeze = dut.u_core.freeze;
    always @(posedge clk)
        if (tracing && !rst && !freeze && dut.u_core.wb_valid) begin
            if (dut.u_core.wb_trap)
                $fdisplay(ftr, "T %08x %08x %08x", dut.u_core.wb_pc, dut.u_core.wb_instr, dut.u_core.wb_cause);
            else begin
                $fwrite(ftr, "C %08x %08x %0d %08x", dut.u_core.wb_pc, dut.u_core.wb_instr,
                        (dut.u_core.wb_rd_we && dut.u_core.wb_rd != 0) ? dut.u_core.wb_rd : 0,
                        (dut.u_core.wb_rd_we && dut.u_core.wb_rd != 0) ? dut.u_core.wb_result : 0);
                if (dut.u_core.wb_store)
                    $fwrite(ftr, " S %08x %08x %x", dut.u_core.wb_result, dut.u_core.wb_wdata, dut.u_core.wb_strb);
                if (dut.u_core.wb_io && dut.u_core.wb_load)
                    $fwrite(ftr, " L %08x", dut.u_core.wb_io_rdata);
                $fwrite(ftr, "\n");
            end
        end

    // ---------------- uart out ----------------
    always @(posedge clk)
        if (!rst && tx_valid)
            $fwrite(fu, "%c", tx_data);

    // ---------------- axi4-lite rules on the cpu side ----------------
    // once valid is up it has to stay up, with the same address / data, until ready
    logic        aw_p, w_p, ar_p;
    logic [31:0] aw_a, w_d, ar_a;
    logic [3:0]  w_s;
    int          axi_errs = 0;
    always @(posedge clk) begin
        if (rst) begin
            aw_p <= 0; w_p <= 0; ar_p <= 0;
        end else begin
            if (aw_p && (!dut.c_awvalid || dut.c_awaddr !== aw_a)) begin
                $display("AXI: awvalid dropped or awaddr changed before awready"); axi_errs++;
            end
            if (w_p && (!dut.c_wvalid || dut.c_wdata !== w_d || dut.c_wstrb !== w_s)) begin
                $display("AXI: wvalid dropped or wdata changed before wready"); axi_errs++;
            end
            if (ar_p && (!dut.c_arvalid || dut.c_araddr !== ar_a)) begin
                $display("AXI: arvalid dropped or araddr changed before arready"); axi_errs++;
            end
            aw_p <= dut.c_awvalid & ~dut.c_awready;  aw_a <= dut.c_awaddr;
            w_p  <= dut.c_wvalid & ~dut.c_wready;    w_d <= dut.c_wdata;  w_s <= dut.c_wstrb;
            ar_p <= dut.c_arvalid & ~dut.c_arready;  ar_a <= dut.c_araddr;
            if (dut.c_bvalid && dut.c_bresp != 2'b00) begin
                $display("AXI: write error response at %08x", aw_a); axi_errs++;
            end
            if (dut.c_rvalid && dut.c_rresp != 2'b00) begin
                $display("AXI: read error response"); axi_errs++;
            end
        end
    end

    // ---------------- run ----------------
    initial begin
        if (!$value$plusargs("hex=%s", hexfile)) hexfile = "prog.hex";
        if (!$value$plusargs("max=%d", maxcyc))  maxcyc = 2000000;
        if (!$value$plusargs("pc=%h", reset_pc)) reset_pc = 32'd0;
        if ($value$plusargs("sdhex=%s", sdfile))
            $readmemh(sdfile, u_sdram.mem);
        tracing = $test$plusargs("trace");
        if ($test$plusargs("vcd")) begin
            $dumpfile("tb_soc.vcd");
            $dumpvars(0, tb_soc);
        end

        for (k = 0; k < (1 << RAM_AW); k++) img[k] = 32'd0;
        $readmemh(hexfile, img);
        for (k = 0; k < (1 << RAM_AW); k++) begin
            dut.u_ram.u_b0.mem[k] = img[k][7:0];
            dut.u_ram.u_b1.mem[k] = img[k][15:8];
            dut.u_ram.u_b2.mem[k] = img[k][23:16];
            dut.u_ram.u_b3.mem[k] = img[k][31:24];
        end
        for (k = 1; k < 32; k++) dut.u_core.rf[k] = 32'd0;

        fu = $fopen("uart.out", "wb");
        if (tracing) ftr = $fopen("trace.txt", "w");

        repeat (4) @(posedge clk);
        @(negedge clk) rst = 1'b0;

        cyc = 0;
        while (!exit_valid && cyc < maxcyc) begin
            @(posedge clk);
            cyc++;
        end
        got_exit = exit_valid;
        // let the last instructions get through WB so the trace is complete
        repeat (8) @(posedge clk);

        fres = $fopen("result.txt", "w");
        if (got_exit)
            $fdisplay(fres, "exit %0d", exit_code);
        else
            $fdisplay(fres, "timeout");
        $fdisplay(fres, "cycles %0d", cyc);
        $fdisplay(fres, "instret %0d", dut.u_core.u_csr.minstret);
        $fdisplay(fres, "axi_errors %0d", axi_errs);
        $fdisplay(fres, "sdram_errors %0d", u_sdram.errors);
        for (k = 1; k < 32; k++)
            $fdisplay(fres, "x%0d %08x", k, dut.u_core.rf[k]);
        $fclose(fres);
        $fclose(fu);
        if (tracing) begin tracing = 0; $fclose(ftr); end

        if (!got_exit)
            $display("TIMEOUT after %0d clocks", cyc);
        else
            $display("EXIT %0d after %0d clocks, %0d instructions", exit_code, cyc, dut.u_core.u_csr.minstret);
        $finish;
    end
endmodule
