// machine timer on axi4-lite, same idea as the clint mtime / mtimecmp
//
//   0x0 / 0x4  mtime lo / hi        counts every clock (27 MHz)
//   0x8 / 0xc  mtimecmp lo / hi     irq is high while mtime >= mtimecmp
//
// mtimecmp starts at all ones so nothing fires until software sets it

module timer_axi (
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

    output wire        irq
);
    wire        wr_en, rd_en;
    wire [11:0] wr_addr, rd_addr;
    wire [31:0] wr_data;
    wire [3:0]  wr_strb;
    reg  [31:0] rd_data;

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

    // byte strobes, so sw / sh / sb all do the right thing
    function [31:0] merge;
        input [31:0] old_v, new_v;
        input [3:0]  strb;
        integer k;
        begin
            for (k = 0; k < 4; k = k + 1)
                merge[8*k +: 8] = strb[k] ? new_v[8*k +: 8] : old_v[8*k +: 8];
        end
    endfunction

    reg [63:0] mtime, mtimecmp;
    assign irq = (mtime >= mtimecmp);

    always @(posedge clk) begin
        if (rst) begin
            mtime    <= 64'd0;
            mtimecmp <= {64{1'b1}};
        end else begin
            mtime <= mtime + 64'd1;
            if (wr_en)
                case (wr_addr[3:2])
                    2'd0: mtime[31:0]     <= merge(mtime[31:0], wr_data, wr_strb);
                    2'd1: mtime[63:32]    <= merge(mtime[63:32], wr_data, wr_strb);
                    2'd2: mtimecmp[31:0]  <= merge(mtimecmp[31:0], wr_data, wr_strb);
                    default: mtimecmp[63:32] <= merge(mtimecmp[63:32], wr_data, wr_strb);
                endcase
        end
    end

    always @(posedge clk)
        if (rd_en)
            case (rd_addr[3:2])
                2'd0: rd_data <= mtime[31:0];
                2'd1: rd_data <= mtime[63:32];
                2'd2: rd_data <= mtimecmp[31:0];
                default: rd_data <= mtimecmp[63:32];
            endcase
endmodule
