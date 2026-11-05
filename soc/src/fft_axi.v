// the fft from 03-fft as an axi4-lite peripheral (256 points, 16 bit re / im)
//
//   0x000  CTRL    write bit 0 = start (ignored while busy)
//   0x004  STAT    bit 0 busy, bit 1 done (cleared by start), bit 2 something clipped
//   0x008  CYCLES  clocks the last run took
//   0x400 + 4k     write: sample k = {re, im}. read: bin k = {re, im}, natural order
//
// samples have to be written while it's idle. the output is fft(x) / 256.

module fft_axi (
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
    input  wire        s_rready
);
    wire        wr_en, rd_en;
    wire [11:0] wr_addr, rd_addr;
    wire [31:0] wr_data;
    wire [3:0]  wr_strb;
    wire [31:0] rd_data;

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

    wire        busy, done, sat;
    wire [15:0] out_re, out_im;
    wire        go     = wr_en & (wr_addr == 12'h000) & wr_data[0] & ~busy;
    wire        win_wr = wr_en & (wr_addr[11:10] == 2'b01);

    fft_core #(.N(256), .W(16), .TW(16)) u_fft (
        .clk(clk), .rst(rst),
        .in_we(win_wr & ~busy), .in_addr(wr_addr[9:2]), .in_re(wr_data[31:16]), .in_im(wr_data[15:0]),
        .out_addr(rd_addr[9:2]), .out_re(out_re), .out_im(out_im),
        .start(go), .busy(busy), .done(done), .sat(sat)
    );

    reg        done_f, win_q;
    reg [31:0] cycles, reg_q;

    always @(posedge clk) begin
        if (rst) begin
            done_f <= 1'b0;
            cycles <= 32'd0;
        end else begin
            if (go) begin
                done_f <= 1'b0;
                cycles <= 32'd0;
            end else if (busy)
                cycles <= cycles + 32'd1;
            if (done)
                done_f <= 1'b1;
        end
    end

    // bins come out of the fft ram one clock after out_addr, same as the regs here
    always @(posedge clk)
        if (rd_en) begin
            win_q <= (rd_addr[11:10] == 2'b01);
            case (rd_addr[3:2])
                2'd1:    reg_q <= {29'd0, sat, done_f, busy};
                2'd2:    reg_q <= cycles;
                default: reg_q <= 32'd0;
            endcase
        end

    assign rd_data = win_q ? {out_re, out_im} : reg_q;
endmodule
