// axi4-lite slave in front of port 0 of sdram_ctrl
// one transaction at a time. a read gets the whole line from the controller and
// hands back the word that was asked for.

module sdram_axi (
    input  wire         clk,
    input  wire         rst,

    input  wire [31:0]  s_awaddr,
    input  wire         s_awvalid,
    output wire         s_awready,
    input  wire [31:0]  s_wdata,
    input  wire [3:0]   s_wstrb,
    input  wire         s_wvalid,
    output wire         s_wready,
    output wire [1:0]   s_bresp,
    output reg          s_bvalid,
    input  wire         s_bready,
    input  wire [31:0]  s_araddr,
    input  wire         s_arvalid,
    output wire         s_arready,
    output reg  [31:0]  s_rdata,
    output wire [1:0]   s_rresp,
    output reg          s_rvalid,
    input  wire         s_rready,

    output reg          req,
    output reg          we,
    output reg  [22:2]  addr,
    output reg  [31:0]  wdata,
    output reg  [3:0]   wstrb,
    input  wire         ack,
    input  wire [127:0] rline
);
    localparam IDLE = 2'd0, BUSY = 2'd1, RESP = 2'd2;
    reg [1:0] st;

    wire take_w = (st == IDLE) & s_awvalid & s_wvalid;
    wire take_r = (st == IDLE) & ~take_w & s_arvalid;

    assign s_awready = take_w;
    assign s_wready  = take_w;
    assign s_arready = take_r;
    assign s_bresp   = 2'b00;
    assign s_rresp   = 2'b00;

    always @(posedge clk) begin
        if (rst) begin
            st       <= IDLE;
            req      <= 1'b0;
            s_bvalid <= 1'b0;
            s_rvalid <= 1'b0;
        end else case (st)
            IDLE: begin
                if (take_w) begin
                    req   <= 1'b1;
                    we    <= 1'b1;
                    addr  <= s_awaddr[22:2];
                    wdata <= s_wdata;
                    wstrb <= s_wstrb;
                    st    <= BUSY;
                end else if (take_r) begin
                    req  <= 1'b1;
                    we   <= 1'b0;
                    addr <= s_araddr[22:2];
                    st   <= BUSY;
                end
            end
            BUSY: if (ack) begin
                req <= 1'b0;
                st  <= RESP;
                if (we)
                    s_bvalid <= 1'b1;
                else begin
                    s_rvalid <= 1'b1;
                    s_rdata  <= rline[32*addr[3:2] +: 32];
                end
            end
            RESP: begin
                if (s_bvalid && s_bready) begin s_bvalid <= 1'b0; st <= IDLE; end
                if (s_rvalid && s_rready) begin s_rvalid <= 1'b0; st <= IDLE; end
            end
            default: st <= IDLE;
        endcase
    end
endmodule
