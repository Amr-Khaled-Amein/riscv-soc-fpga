// axi4-lite slave front end -> simple register bus
//
//   wr_en  1 clock, with wr_addr / wr_data / wr_strb
//   rd_en  1 clock with rd_addr, the register block has to put rd_data out
//          on the next clock (a registered read, which is what bsram gives too)
//
// one transaction at a time, which is all the cpu ever does. a write waits until
// both aw and w are there.

module axil_slave (
    input  wire        clk,
    input  wire        rst,

    input  wire [31:0] s_awaddr,
    input  wire        s_awvalid,
    output wire        s_awready,
    input  wire [31:0] s_wdata,
    input  wire [3:0]  s_wstrb,
    input  wire        s_wvalid,
    output wire        s_wready,
    output wire [1:0]  s_bresp,
    output reg         s_bvalid,
    input  wire        s_bready,
    input  wire [31:0] s_araddr,
    input  wire        s_arvalid,
    output wire        s_arready,
    output reg  [31:0] s_rdata,
    output wire [1:0]  s_rresp,
    output reg         s_rvalid,
    input  wire        s_rready,

    output wire        wr_en,
    output wire [11:0] wr_addr,
    output wire [31:0] wr_data,
    output wire [3:0]  wr_strb,
    output wire        rd_en,
    output wire [11:0] rd_addr,
    input  wire [31:0] rd_data
);
    reg rd_wait;

    assign wr_en     = s_awvalid & s_wvalid & ~s_bvalid;
    assign s_awready = wr_en;
    assign s_wready  = wr_en;
    assign wr_addr   = s_awaddr[11:0];
    assign wr_data   = s_wdata;
    assign wr_strb   = s_wstrb;
    assign s_bresp   = 2'b00;

    assign rd_en     = s_arvalid & ~rd_wait & ~s_rvalid;
    assign s_arready = rd_en;
    assign rd_addr   = s_araddr[11:0];
    assign s_rresp   = 2'b00;

    always @(posedge clk) begin
        if (rst) begin
            s_bvalid <= 1'b0;
            s_rvalid <= 1'b0;
            rd_wait  <= 1'b0;
            s_rdata  <= 32'd0;
        end else begin
            if (wr_en)
                s_bvalid <= 1'b1;
            else if (s_bready)
                s_bvalid <= 1'b0;

            rd_wait <= rd_en;
            if (rd_wait) begin
                s_rvalid <= 1'b1;
                s_rdata  <= rd_data;
            end else if (s_rready)
                s_rvalid <= 1'b0;
        end
    end
endmodule
