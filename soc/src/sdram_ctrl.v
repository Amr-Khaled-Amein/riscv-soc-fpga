// controller for the 64 Mbit sdram inside the GW2AR-18 (2K rows x 256 cols x 4 banks x 32 bit)
//
// two ports, port 0 (data / loader) wins over port 1 (instruction fetch).
// a request stays up until ack. reads always fetch the whole 16 byte line
// (burst of 4) and hand back all 4 words, writes are one word with byte enables.
// every access opens the row and closes it again (auto precharge), no open row
// tricks, so an access is always the same few clocks.
//
// the sdram clock is our clock inverted: it samples the commands in the middle of
// our clock. with cas latency 2 the first word is valid one sdram clock after the
// next one, so data from a READ put out in clock n gets caught at the end of
// clocks n+1 .. n+4.
//
// 27 MHz = 37 ns per clock, so tRCD / tRP / tRC are all covered with 1-2 clocks.
// refresh: 4096 rows per 64 ms = one every 15.6 us, this does one every 256 clocks.

module sdram_ctrl #(
    parameter INIT_WAIT = 6000          // 200 us at 27 MHz before touching it
)(
    input  wire         clk,
    input  wire         rst,

    input  wire         p0_req,
    input  wire         p0_we,
    input  wire [22:2]  p0_addr,        // word address inside the 8 MB
    input  wire [31:0]  p0_wdata,
    input  wire [3:0]   p0_wstrb,
    output reg          p0_ack,

    input  wire         p1_req,
    input  wire [22:2]  p1_addr,
    output reg          p1_ack,

    output reg  [127:0] rline,          // line of the last read, word 0 in the low bits
    output wire         ready,          // init done

    // pins
    output wire         sd_clk,
    output wire         sd_cke,
    output wire         sd_cs_n,
    output reg          sd_ras_n,
    output reg          sd_cas_n,
    output reg          sd_we_n,
    output reg  [10:0]  sd_addr,
    output reg  [1:0]   sd_ba,
    output reg  [3:0]   sd_dqm,
    inout  wire [31:0]  sd_dq
);
    // ras cas we
    localparam C_NOP = 3'b111, C_ACT = 3'b011, C_RD = 3'b101, C_WR = 3'b100,
               C_PRE = 3'b010, C_REF = 3'b001, C_MRS = 3'b000;

    // burst 4, sequential, cas 2, single word writes
    localparam [10:0] MODE = 11'b0_1_00_010_0_010;

    localparam S_INIT = 3'd0, S_IDLE = 3'd1, S_READ = 3'd2, S_WRITE = 3'd3, S_REF = 3'd4;

    reg [2:0]  st;
    reg [12:0] cnt;
    reg [3:0]  step;
    reg [7:0]  ref_cnt;
    reg        ref_due, inited;
    reg        port;            // which port is being served
    reg [22:2] a;
    reg [31:0] wd;
    reg [3:0]  ws;

    reg        dq_oe;
    reg [31:0] dq_out;
    assign sd_dq   = dq_oe ? dq_out : 32'bz;
    assign sd_clk  = ~clk;
    assign sd_cke  = 1'b1;
    assign sd_cs_n = 1'b0;
    assign ready   = inited;

    // address split: bank | row | column
    wire [1:0]  bank = a[22:21];
    wire [10:0] row  = a[20:10];
    wire [7:0]  col  = a[9:2];

    task cmd;
        input [2:0] c;
        {sd_ras_n, sd_cas_n, sd_we_n} = c;
    endtask

    always @(posedge clk) begin
        p0_ack <= 1'b0;
        p1_ack <= 1'b0;
        cmd(C_NOP);
        dq_oe  <= 1'b0;

        if (ref_cnt == 8'd255)
            ref_due <= 1'b1;
        ref_cnt <= ref_cnt + 8'd1;

        if (rst) begin
            st      <= S_INIT;
            cnt     <= 13'd0;
            step    <= 4'd0;
            inited  <= 1'b0;
            ref_due <= 1'b0;
            ref_cnt <= 8'd0;
            sd_dqm  <= 4'b1111;
            sd_addr <= 11'd0;
            sd_ba   <= 2'd0;
        end else case (st)
            // power up: wait, precharge all, 2 refreshes, mode register
            S_INIT: begin
                cnt <= cnt + 13'd1;
                if (cnt == INIT_WAIT)      begin cmd(C_PRE); sd_addr[10] <= 1'b1; end
                if (cnt == INIT_WAIT + 3)  cmd(C_REF);
                if (cnt == INIT_WAIT + 9)  cmd(C_REF);
                if (cnt == INIT_WAIT + 15) begin cmd(C_MRS); sd_addr <= MODE; sd_ba <= 2'd0; end
                if (cnt == INIT_WAIT + 19) begin
                    st      <= S_IDLE;
                    inited  <= 1'b1;
                    ref_due <= 1'b0;
                end
            end

            S_IDLE: begin
                step <= 4'd0;
                if (ref_due) begin
                    cmd(C_REF);
                    ref_due <= 1'b0;
                    st      <= S_REF;
                end else if (p0_req || p1_req) begin
                    port <= ~p0_req;
                    a    <= p0_req ? p0_addr : p1_addr;
                    wd   <= p0_wdata;
                    ws   <= p0_wstrb;
                    // open the row
                    cmd(C_ACT);
                    sd_ba   <= p0_req ? p0_addr[22:21] : p1_addr[22:21];
                    sd_addr <= p0_req ? p0_addr[20:10] : p1_addr[20:10];
                    st      <= (p0_req && p0_we) ? S_WRITE : S_READ;
                end
            end

            // clk 0 ACT (in idle), 2 READ + auto precharge, data at the end of 3..6
            S_READ: begin
                step <= step + 4'd1;
                if (step == 4'd1) begin
                    cmd(C_RD);
                    sd_addr <= {1'b1, 2'b00, col[7:2], 2'b00};
                    sd_dqm  <= 4'b0000;
                end
                if (step >= 4'd3 && step <= 4'd6)
                    rline <= {sd_dq, rline[127:32]};
                if (step == 4'd6) begin
                    if (port) p1_ack <= 1'b1;
                    else      p0_ack <= 1'b1;
                end
                if (step == 4'd9)
                    st <= S_IDLE;
            end

            // clk 0 ACT, 2 WRITE + auto precharge with the data, then tWR + tRP
            S_WRITE: begin
                step <= step + 4'd1;
                if (step == 4'd1) begin
                    cmd(C_WR);
                    sd_addr <= {1'b1, 2'b00, col};
                    sd_dqm  <= ~ws;
                    dq_out  <= wd;
                    dq_oe   <= 1'b1;
                end
                if (step == 4'd2)
                    p0_ack <= 1'b1;
                if (step == 4'd6)
                    st <= S_IDLE;
            end

            S_REF: begin
                step <= step + 4'd1;
                if (step == 4'd5)
                    st <= S_IDLE;
            end

            default: st <= S_INIT;
        endcase
    end
endmodule
