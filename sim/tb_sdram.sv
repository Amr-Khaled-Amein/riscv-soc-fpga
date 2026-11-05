// tb_sdram - sdram_ctrl against sdram_model: random writes (with byte enables)
// and line reads from both ports, checked against a plain array. prints PASS / FAIL

`timescale 1ns/1ps

module tb_sdram;
    logic clk = 1'b0, rst = 1'b1;
    always #18.5 clk = ~clk;

    logic        p0_req = 0, p0_we = 0, p1_req = 0;
    logic [22:2] p0_addr = 0, p1_addr = 0;
    logic [31:0] p0_wdata = 0;
    logic [3:0]  p0_wstrb = 0;
    wire         p0_ack, p1_ack, ready;
    wire [127:0] rline;
    wire         sd_clk, sd_cke, sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n;
    wire [10:0]  sd_addr;
    wire [1:0]   sd_ba;
    wire [3:0]   sd_dqm;
    wire [31:0]  sd_dq;

    sdram_ctrl #(.INIT_WAIT(100)) dut (
        .clk(clk), .rst(rst),
        .p0_req(p0_req), .p0_we(p0_we), .p0_addr(p0_addr), .p0_wdata(p0_wdata), .p0_wstrb(p0_wstrb), .p0_ack(p0_ack),
        .p1_req(p1_req), .p1_addr(p1_addr), .p1_ack(p1_ack), .rline(rline), .ready(ready),
        .sd_clk(sd_clk), .sd_cke(sd_cke), .sd_cs_n(sd_cs_n), .sd_ras_n(sd_ras_n), .sd_cas_n(sd_cas_n),
        .sd_we_n(sd_we_n), .sd_addr(sd_addr), .sd_ba(sd_ba), .sd_dqm(sd_dqm), .sd_dq(sd_dq));

    sdram_model mem (.clk(sd_clk), .cke(sd_cke), .cs_n(sd_cs_n), .ras_n(sd_ras_n), .cas_n(sd_cas_n),
        .we_n(sd_we_n), .addr(sd_addr), .ba(sd_ba), .dqm(sd_dqm), .dq(sd_dq));

    // reference, only a small window so reads hit written data often
    localparam NW = 4096;
    logic [31:0] ref_m [0:NW-1];
    logic [22:2] base;
    int bad = 0, nrd = 0, nwr = 0;

    function automatic logic [22:2] pick();
        // spread over banks / rows, stay inside NW words
        return base + $urandom_range(0, NW - 1);
    endfunction

    task automatic wr(input logic [22:2] a, input logic [31:0] d, input logic [3:0] s);
        @(negedge clk);
        p0_req = 1; p0_we = 1; p0_addr = a; p0_wdata = d; p0_wstrb = s;
        do @(posedge clk); while (!p0_ack);
        @(negedge clk) p0_req = 0;
        for (int k = 0; k < 4; k++)
            if (s[k]) ref_m[a - base][8*k +: 8] = d[8*k +: 8];
        nwr++;
    endtask

    task automatic rd(input int port, input logic [22:2] a);
        logic [22:2] l;
        @(negedge clk);
        if (port == 0) begin p0_req = 1; p0_we = 0; p0_addr = a; end
        else begin p1_req = 1; p1_addr = a; end
        if (port == 0) do @(posedge clk); while (!p0_ack);
        else           do @(posedge clk); while (!p1_ack);
        @(negedge clk) begin p0_req = 0; p1_req = 0; end
        l = {a[22:4], 2'b00};
        for (int k = 0; k < 4; k++)
            if (l + k - base < NW && rline[32*k +: 32] !== ref_m[l + k - base]) begin
                if (bad < 5) $display("  read %06x word %0d: got %08x want %08x", a, k, rline[32*k +: 32], ref_m[l + k - base]);
                bad++;
            end
        nrd++;
    endtask

    initial begin
        base = 21'h0f_f000 & ~21'h3;           // crosses a bank boundary at 0x100000
        for (int i = 0; i < NW; i++) begin
            ref_m[i] = $urandom;
            mem.mem[base + i] = ref_m[i];
        end
        base = base & ~21'h3;
        repeat (4) @(posedge clk);
        rst = 0;
        wait (ready);
        for (int i = 0; i < 3000; i++) begin
            case ($urandom_range(0, 2))
                0: wr(pick(), $urandom, $urandom_range(1, 15));
                1: rd(0, pick() & ~21'h3);
                2: rd(1, pick() & ~21'h3);
            endcase
            // sometimes sit idle long enough for refreshes to land in between
            if ($urandom_range(0, 20) == 0) repeat ($urandom_range(50, 400)) @(posedge clk);
        end
        // both ports at once, port 0 has to go first
        @(negedge clk);
        p0_req = 1; p0_we = 0; p0_addr = base; p1_req = 1; p1_addr = base + 8;
        do @(posedge clk); while (!(p0_ack | p1_ack));
        if (!p0_ack) begin $display("  port 1 went first"); bad++; end
        @(negedge clk) p0_req = 0;
        do @(posedge clk); while (!p1_ack);
        @(negedge clk) p1_req = 0;

        if (bad == 0 && mem.errors == 0)
            $display("PASS: %0d writes, %0d line reads, no sdram rule broken", nwr, nrd);
        else
            $display("FAIL: %0d bad words, %0d sdram errors", bad, mem.errors);
        $finish;
    end
endmodule
