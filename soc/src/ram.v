// main memory, 2^AW words, made of 4 byte lanes so stores can write single bytes

module ram #(
    parameter AW = 14
)(
    input  wire          clk,
    input  wire [AW-1:0] a_addr,
    output wire [31:0]   a_rdata,
    input  wire [AW-1:0] b_addr,
    input  wire [3:0]    b_we,
    input  wire [31:0]   b_wdata,
    output wire [31:0]   b_rdata
);
    ram_lane #(.AW(AW)) u_b0 (.clk(clk), .a_addr(a_addr), .a_rdata(a_rdata[7:0]),
        .b_addr(b_addr), .b_we(b_we[0]), .b_wdata(b_wdata[7:0]), .b_rdata(b_rdata[7:0]));
    ram_lane #(.AW(AW)) u_b1 (.clk(clk), .a_addr(a_addr), .a_rdata(a_rdata[15:8]),
        .b_addr(b_addr), .b_we(b_we[1]), .b_wdata(b_wdata[15:8]), .b_rdata(b_rdata[15:8]));
    ram_lane #(.AW(AW)) u_b2 (.clk(clk), .a_addr(a_addr), .a_rdata(a_rdata[23:16]),
        .b_addr(b_addr), .b_we(b_we[2]), .b_wdata(b_wdata[23:16]), .b_rdata(b_rdata[23:16]));
    ram_lane #(.AW(AW)) u_b3 (.clk(clk), .a_addr(a_addr), .a_rdata(a_rdata[31:24]),
        .b_addr(b_addr), .b_we(b_we[3]), .b_wdata(b_wdata[31:24]), .b_rdata(b_rdata[31:24]));
endmodule
