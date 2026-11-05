// axi4-lite interconnect, 1 master -> NS slaves
// slave i < NS-1 lives at 0x1000_0000 + i * 0x1000 (4 KB each), the last one is the
// sdram at 0x8000_0000 (8 MB). anything else gets DECERR.
//
// the target is picked when aw / ar shows up and held until the response is
// done, so a write or read always talks to one slave start to finish.

module axil_xbar #(
    parameter NS = 5
)(
    input  wire           clk,
    input  wire           rst,

    // from the master
    input  wire [31:0]    s_awaddr,
    input  wire           s_awvalid,
    output reg            s_awready,
    input  wire [31:0]    s_wdata,
    input  wire [3:0]     s_wstrb,
    input  wire           s_wvalid,
    output reg            s_wready,
    output reg  [1:0]     s_bresp,
    output reg            s_bvalid,
    input  wire           s_bready,
    input  wire [31:0]    s_araddr,
    input  wire           s_arvalid,
    output reg            s_arready,
    output reg  [31:0]    s_rdata,
    output reg  [1:0]     s_rresp,
    output reg            s_rvalid,
    input  wire           s_rready,

    // to the slaves, all of them see the same address / data
    output wire [31:0]    m_awaddr,
    output wire [NS-1:0]  m_awvalid,
    input  wire [NS-1:0]  m_awready,
    output wire [31:0]    m_wdata,
    output wire [3:0]     m_wstrb,
    output wire [NS-1:0]  m_wvalid,
    input  wire [NS-1:0]  m_wready,
    input  wire [2*NS-1:0] m_bresp,
    input  wire [NS-1:0]  m_bvalid,
    output wire [NS-1:0]  m_bready,
    output wire [31:0]    m_araddr,
    output wire [NS-1:0]  m_arvalid,
    input  wire [NS-1:0]  m_arready,
    input  wire [32*NS-1:0] m_rdata,
    input  wire [2*NS-1:0] m_rresp,
    input  wire [NS-1:0]  m_rvalid,
    output wire [NS-1:0]  m_rready
);
    localparam SB = $clog2(NS + 1);
    localparam ERR = NS;                    // index of the "nobody" slave

    function [SB-1:0] decode;
        input [31:0] a;
        if (a[31:16] == 16'h1000 && a[15:12] < NS - 1)
            decode = a[12 +: SB];
        else if (a[31:23] == 9'h100)
            decode = NS - 1;
        else
            decode = ERR;
    endfunction

    // ---------------- write ----------------
    reg          w_act;                     // a write is going on
    reg [SB-1:0] w_sel;
    reg          aw_done, w_done, eb_valid;  // eb = error response

    assign m_awaddr = s_awaddr;
    assign m_wdata  = s_wdata;
    assign m_wstrb  = s_wstrb;

    genvar i;
    generate
        for (i = 0; i < NS; i = i + 1) begin : g_w
            assign m_awvalid[i] = w_act & (w_sel == i) & s_awvalid & ~aw_done;
            assign m_wvalid[i]  = w_act & (w_sel == i) & s_wvalid & ~w_done;
            assign m_bready[i]  = w_act & (w_sel == i) & s_bready;
        end
    endgenerate

    always @(*) begin
        s_awready = 1'b0;
        s_wready  = 1'b0;
        s_bvalid  = 1'b0;
        s_bresp   = 2'b00;
        if (w_act) begin
            if (w_sel == ERR) begin
                s_awready = ~aw_done;
                s_wready  = ~w_done;
                s_bvalid  = eb_valid;
                s_bresp   = 2'b11;
            end else begin
                s_awready = m_awready[w_sel] & ~aw_done;
                s_wready  = m_wready[w_sel] & ~w_done;
                s_bvalid  = m_bvalid[w_sel];
                s_bresp   = m_bresp[2*w_sel +: 2];
            end
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            w_act    <= 1'b0;
            aw_done  <= 1'b0;
            w_done   <= 1'b0;
            eb_valid <= 1'b0;
            w_sel    <= ERR;
        end else if (!w_act) begin
            if (s_awvalid) begin
                w_act   <= 1'b1;
                w_sel   <= decode(s_awaddr);
                aw_done <= 1'b0;
                w_done  <= 1'b0;
            end
        end else begin
            if (s_awvalid && s_awready) aw_done <= 1'b1;
            if (s_wvalid && s_wready)   w_done  <= 1'b1;
            // the error slave answers once it has both
            if (w_sel == ERR && aw_done && w_done && !eb_valid)
                eb_valid <= 1'b1;
            if (s_bvalid && s_bready) begin
                w_act    <= 1'b0;
                eb_valid <= 1'b0;
            end
        end
    end

    // ---------------- read ----------------
    reg          r_act, ar_done, er_valid;
    reg [SB-1:0] r_sel;

    assign m_araddr = s_araddr;

    generate
        for (i = 0; i < NS; i = i + 1) begin : g_r
            assign m_arvalid[i] = r_act & (r_sel == i) & s_arvalid & ~ar_done;
            assign m_rready[i]  = r_act & (r_sel == i) & s_rready;
        end
    endgenerate

    always @(*) begin
        s_arready = 1'b0;
        s_rvalid  = 1'b0;
        s_rdata   = 32'd0;
        s_rresp   = 2'b00;
        if (r_act) begin
            if (r_sel == ERR) begin
                s_arready = ~ar_done;
                s_rvalid  = er_valid;
                s_rresp   = 2'b11;
            end else begin
                s_arready = m_arready[r_sel] & ~ar_done;
                s_rvalid  = m_rvalid[r_sel];
                s_rdata   = m_rdata[32*r_sel +: 32];
                s_rresp   = m_rresp[2*r_sel +: 2];
            end
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            r_act    <= 1'b0;
            ar_done  <= 1'b0;
            er_valid <= 1'b0;
            r_sel    <= ERR;
        end else if (!r_act) begin
            if (s_arvalid) begin
                r_act   <= 1'b1;
                r_sel   <= decode(s_araddr);
                ar_done <= 1'b0;
            end
        end else begin
            if (s_arvalid && s_arready) ar_done <= 1'b1;
            if (r_sel == ERR && ar_done && !er_valid)
                er_valid <= 1'b1;
            if (s_rvalid && s_rready) begin
                r_act    <= 1'b0;
                er_valid <= 1'b0;
            end
        end
    end
endmodule
