// behavioural model of the 64 Mbit sdram in the GW2AR-18 (2K rows x 256 cols x 4 banks x 32)
// only what the controller uses: ACT, READ/WRITE with or without auto precharge,
// PRECHARGE, AUTO REFRESH, MODE REGISTER. reads come out cas latency clocks later.
// complains (errors++) about anything that would break a real chip:
//   act on an open bank, read/write on a closed bank, refresh with a bank open,
//   commands before the mode register is set, too long between refreshes,
//   a write while it's still driving read data

`timescale 1ns/1ps

module sdram_model #(
    parameter REF_MAX = 20000      // ns between refreshes, the real limit is 15.6 us average
)(
    input  wire        clk,         // the sdram clock
    input  wire        cke,
    input  wire        cs_n,
    input  wire        ras_n,
    input  wire        cas_n,
    input  wire        we_n,
    input  wire [10:0] addr,
    input  wire [1:0]  ba,
    input  wire [3:0]  dqm,
    inout  wire [31:0] dq
);
    logic [31:0] mem [0:(1<<21)-1];
    int          errors = 0;

    logic        open_b [0:3];
    logic [10:0] row_b  [0:3];
    logic [2:0]  cl = 3'd0, bl = 3'd0;
    logic        mode_set = 1'b0, single_wr = 1'b0;
    realtime     last_ref = 0;
    bit          seen_ref = 0;

    // read data pipeline, one slot per clock
    logic        p_v [0:15];
    logic [31:0] p_d [0:15];
    logic        drive = 1'b0;
    logic [31:0] dout;
    assign dq = drive ? dout : 32'bz;

    initial
        for (int i = 0; i < 4; i++) open_b[i] = 1'b0;
    initial
        for (int i = 0; i < 16; i++) p_v[i] = 1'b0;

    task bad(input string s);
        errors++;
        if (errors < 10) $display("SDRAM: %s at %0t", s, $realtime);
    endtask

    wire [2:0] c = {ras_n, cas_n, we_n};

    always @(posedge clk) begin : step
        int b, w, n;
        logic [21:0] wa;

        // move the read pipeline on, slot 0 is what goes out during this clock
        for (int i = 0; i < 15; i++) begin
            p_v[i] = p_v[i + 1];
            p_d[i] = p_d[i + 1];
        end
        p_v[15] = 1'b0;

        if (!cs_n && cke) begin
            b = ba;
            case (c)
                3'b011: begin   // activate
                    if (!mode_set) bad("ACT before mode register");
                    if (open_b[b]) bad("ACT on an open bank");
                    open_b[b] = 1'b1;
                    row_b[b]  = addr;
                end
                3'b101, 3'b100: begin   // read / write
                    if (!open_b[b]) bad("READ/WRITE on a closed bank");
                    wa = {ba, row_b[b], addr[7:0]};
                    if (c == 3'b101) begin
                        n = 1 << bl;
                        for (int i = 0; i < n; i++) begin
                            // sequential burst wraps inside the burst length
                            w = (wa & ~(n - 1)) | ((wa + i) & (n - 1));
                            // a read at edge n with latency cl is valid at edge n + cl,
                            // so it gets driven right after edge n + cl - 1
                            p_v[cl - 1 + i] = 1'b1;
                            p_d[cl - 1 + i] = mem[w];
                        end
                    end else begin
                        if (drive) bad("WRITE while the sdram drives read data");
                        if (!single_wr && bl != 0) bad("burst writes are not expected");
                        for (int k = 0; k < 4; k++)
                            if (!dqm[k]) mem[wa][8*k +: 8] = dq[8*k +: 8];
                    end
                    if (addr[10]) open_b[b] = 1'b0;     // auto precharge
                end
                3'b010: begin   // precharge
                    if (addr[10])
                        for (int i = 0; i < 4; i++) open_b[i] = 1'b0;
                    else
                        open_b[b] = 1'b0;
                end
                3'b001: begin   // auto refresh
                    for (int i = 0; i < 4; i++)
                        if (open_b[i]) bad("REFRESH with a bank open");
                    if (seen_ref && mode_set && $realtime - last_ref > REF_MAX) bad("refresh came too late");
                    last_ref = $realtime;
                    seen_ref = 1;
                end
                3'b000: begin   // mode register
                    bl        = addr[2:0];
                    cl        = addr[6:4];
                    single_wr = addr[9];
                    mode_set  = 1'b1;
                    if (cl != 3'd2 && cl != 3'd3) bad("odd cas latency");
                end
                default: ;
            endcase
        end
        if (mode_set && seen_ref && $realtime - last_ref > REF_MAX) begin
            bad("no refresh for too long");
            last_ref = $realtime;
        end

        // output after a short clock to out delay
        #3;
        drive = p_v[0];
        dout  = p_v[0] ? p_d[0] : 32'hxxxxxxxx;
    end
endmodule
