// small system block on axi4-lite
//
//   0x0  LED     bits 4:0 drive led 0-4 (1 = on)
//   0x4  EXIT    write: the program is done, the value is the exit code
//   0x8  CLK_HZ  read only, clock frequency
//   0xc  SCRATCH plain read / write register (bus test)

module sys_axi #(
    parameter CLK_HZ = 27000000
)(
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
    output wire        s_bvalid,
    input  wire        s_bready,
    input  wire [31:0] s_araddr,
    input  wire        s_arvalid,
    output wire        s_arready,
    output wire [31:0] s_rdata,
    output wire [1:0]  s_rresp,
    output wire        s_rvalid,
    input  wire        s_rready,

    output reg  [4:0]  led,
    output reg         exit_valid,      // 1 clock
    output reg  [31:0] exit_code
);
    wire        wr_en, rd_en;
    wire [11:0] wr_addr, rd_addr;
    wire [31:0] wr_data;
    wire [3:0]  wr_strb;
    reg  [31:0] rd_data;
    reg  [31:0] scratch;

    // byte strobes, so sb / sh only change their bytes
    function [31:0] merge;
        input [31:0] old_v, new_v;
        input [3:0]  strb;
        integer k;
        begin
            for (k = 0; k < 4; k = k + 1)
                merge[8*k +: 8] = strb[k] ? new_v[8*k +: 8] : old_v[8*k +: 8];
        end
    endfunction

    axil_slave u_axi (
        .clk(clk), .rst(rst),
        .s_awaddr(s_awaddr), .s_awvalid(s_awvalid), .s_awready(s_awready),
        .s_wdata(s_wdata), .s_wstrb(s_wstrb), .s_wvalid(s_wvalid), .s_wready(s_wready),
        .s_bresp(s_bresp), .s_bvalid(s_bvalid), .s_bready(s_bready),
        .s_araddr(s_araddr), .s_arvalid(s_arvalid), .s_arready(s_arready),
        .s_rdata(s_rdata), .s_rresp(s_rresp), .s_rvalid(s_rvalid), .s_rready(s_rready),
        .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data), .wr_strb(wr_strb),
        .rd_en(rd_en), .rd_addr(rd_addr), .rd_data(rd_data)
    );

    always @(posedge clk) begin
        exit_valid <= 1'b0;
        if (rst) begin
            led       <= 5'd0;
            exit_code <= 32'd0;
            scratch   <= 32'd0;
        end else if (wr_en) begin
            case (wr_addr[3:2])
                2'd0: if (wr_strb[0]) led <= wr_data[4:0];
                2'd1: begin exit_valid <= 1'b1; exit_code <= wr_data; end
                2'd3: scratch <= merge(scratch, wr_data, wr_strb);
                default: ;
            endcase
        end
    end

    always @(posedge clk)
        if (rd_en)
            case (rd_addr[3:2])
                2'd0: rd_data <= {27'd0, led};
                2'd1: rd_data <= exit_code;
                2'd2: rd_data <= CLK_HZ;
                default: rd_data <= scratch;
            endcase
endmodule
