// the soc without the uart pins: core + memories + axi4-lite bus + peripherals
//
// memory map
//   0x0000_0000  block ram, 4 * 2^RAM_AW bytes (64 KB), 1 clock
//   0x1000_0000  uart
//   0x1000_1000  timer
//   0x1000_2000  fft
//   0x1000_3000  sys (leds, exit)
//   0x8000_0000  sdram, 8 MB. loads/stores go over axi, code fetch has its own
//                port with a one line (16 byte) buffer
//
// while cpu_rst is high the loader can read/write both memories

module soc #(
    parameter RAM_AW  = 14,
    parameter CLK_HZ  = 27000000,
    parameter SD_INIT = 6000
)(
    input  wire        clk,
    input  wire        rst,           // power on, only the sdram controller
    input  wire        cpu_rst,       // core
    input  wire        io_rst,        // bus + peripherals
    input  wire [31:0] reset_pc,

    // loader, one byte at a time, only while cpu_rst
    input  wire        ld_req,
    input  wire        ld_we,
    input  wire [31:0] ld_addr,
    input  wire [7:0]  ld_wdata,
    output wire        ld_ack,
    output wire [31:0] ld_rdata,      // the whole word around the byte

    // uart bytes
    output wire [7:0]  tx_data,
    output wire        tx_valid,
    input  wire        tx_ready,
    input  wire [7:0]  rx_data,
    input  wire        rx_valid,
    output wire        tx_idle,

    output wire [4:0]  led,
    output wire        exit_valid,
    output wire [31:0] exit_code,

    // sdram pins
    output wire        sd_clk,
    output wire        sd_cke,
    output wire        sd_cs_n,
    output wire        sd_ras_n,
    output wire        sd_cas_n,
    output wire        sd_we_n,
    output wire [10:0] sd_addr,
    output wire [1:0]  sd_ba,
    output wire [3:0]  sd_dqm,
    inout  wire [31:0] sd_dq
);
    localparam NS = 5;

    function in_ram;
        input [31:0] a;
        in_ram = (a[31:RAM_AW+2] == 0);
    endfunction

    function in_sd;
        input [31:0] a;
        in_sd = (a[31:23] == 9'h100);
    endfunction

    // ---------------- core ----------------
    wire [31:0] i_addr, i_rdata, d_addr, d_wdata, d_rdata, ram_i_rdata;
    wire [3:0]  d_we;
    wire        i_wait, irq_timer;

    wire [31:0] c_awaddr, c_wdata, c_araddr, c_rdata;
    wire [3:0]  c_wstrb;
    wire [1:0]  c_bresp, c_rresp;
    wire        c_awvalid, c_awready, c_wvalid, c_wready, c_bvalid, c_bready;
    wire        c_arvalid, c_arready, c_rvalid, c_rready;

    rv_core #(.RAM_AW(RAM_AW)) u_core (
        .clk(clk), .rst(cpu_rst), .reset_pc(reset_pc),
        .i_addr(i_addr), .i_rdata(i_rdata), .i_wait(i_wait),
        .d_addr(d_addr), .d_we(d_we), .d_wdata(d_wdata), .d_rdata(d_rdata),
        .m_awaddr(c_awaddr), .m_awvalid(c_awvalid), .m_awready(c_awready),
        .m_wdata(c_wdata), .m_wstrb(c_wstrb), .m_wvalid(c_wvalid), .m_wready(c_wready),
        .m_bresp(c_bresp), .m_bvalid(c_bvalid), .m_bready(c_bready),
        .m_araddr(c_araddr), .m_arvalid(c_arvalid), .m_arready(c_arready),
        .m_rdata(c_rdata), .m_rresp(c_rresp), .m_rvalid(c_rvalid), .m_rready(c_rready),
        .irq_timer(irq_timer)
    );

    // ---------------- block ram ----------------
    // loader access: address in the first clock, data back in the second
    wire ld_ram = ld_req & in_ram(ld_addr);
    wire ld_sd  = ld_req & in_sd(ld_addr);
    reg  ld_ph;
    always @(posedge clk)
        ld_ph <= ld_ram & ~ld_ph;

    wire [RAM_AW-1:0] b_addr  = cpu_rst ? ld_addr[RAM_AW+1:2] : d_addr[RAM_AW+1:2];
    wire [3:0]        b_we    = cpu_rst ? ((ld_ram & ld_we & ~ld_ph) ? (4'b0001 << ld_addr[1:0]) : 4'd0) : d_we;
    wire [31:0]       b_wdata = cpu_rst ? {4{ld_wdata}} : d_wdata;

    ram #(.AW(RAM_AW)) u_ram (
        .clk(clk),
        .a_addr(i_addr[RAM_AW+1:2]), .a_rdata(ram_i_rdata),
        .b_addr(b_addr), .b_we(b_we), .b_wdata(b_wdata), .b_rdata(d_rdata)
    );

    // ---------------- sdram ----------------
    wire         p0_req, p0_we, p0_ack, p1_ack, sd_ready;
    wire [22:2]  p0_addr;
    wire [31:0]  p0_wdata;
    wire [3:0]   p0_wstrb;
    wire [127:0] rline;
    wire         a_req, a_we;
    wire [22:2]  a_addr;
    wire [31:0]  a_wdata;
    wire [3:0]   a_wstrb;
    reg          f_pend;
    reg  [22:4]  f_line;

    // port 0 is the cpu (through axi) or the loader
    assign p0_req   = cpu_rst ? ld_sd : a_req;
    assign p0_we    = cpu_rst ? ld_we : a_we;
    assign p0_addr  = cpu_rst ? ld_addr[22:2] : a_addr;
    assign p0_wdata = cpu_rst ? {4{ld_wdata}} : a_wdata;
    assign p0_wstrb = cpu_rst ? (4'b0001 << ld_addr[1:0]) : a_wstrb;

    sdram_ctrl #(.INIT_WAIT(SD_INIT)) u_sdram (
        .clk(clk), .rst(rst),
        .p0_req(p0_req), .p0_we(p0_we), .p0_addr(p0_addr), .p0_wdata(p0_wdata), .p0_wstrb(p0_wstrb),
        .p0_ack(p0_ack),
        .p1_req(f_pend), .p1_addr({f_line, 2'b00}), .p1_ack(p1_ack),
        .rline(rline), .ready(sd_ready),
        .sd_clk(sd_clk), .sd_cke(sd_cke), .sd_cs_n(sd_cs_n), .sd_ras_n(sd_ras_n), .sd_cas_n(sd_cas_n),
        .sd_we_n(sd_we_n), .sd_addr(sd_addr), .sd_ba(sd_ba), .sd_dqm(sd_dqm), .sd_dq(sd_dq)
    );

    // anything else the loader asks for just gets acked
    assign ld_ack   = ld_ram ? ld_ph : ld_sd ? p0_ack : ld_req;
    assign ld_rdata = ld_ram ? d_rdata : rline[32*ld_addr[3:2] +: 32];

    // ---------------- instruction fetch ----------------
    // fpc = address the core asked for last clock (its id_pc). from sdram it comes
    // out of a one line buffer, a miss reads the line and the core waits
    reg  [31:0]  fpc;
    reg          fb_valid;
    reg  [22:4]  fb_line;
    reg  [127:0] fb_data;

    wire f_sd  = in_sd(fpc);
    wire f_hit = fb_valid & (fb_line == fpc[22:4]);
    assign i_wait  = f_sd & ~f_hit;
    assign i_rdata = f_sd ? fb_data[32*fpc[3:2] +: 32] : ram_i_rdata;

    always @(posedge clk) begin
        fpc <= i_addr;
        if (cpu_rst) begin
            fb_valid <= 1'b0;
            f_pend   <= 1'b0;
        end else begin
            if (!f_pend && f_sd && !f_hit) begin
                f_pend <= 1'b1;
                f_line <= fpc[22:4];
            end
            if (p1_ack) begin
                f_pend   <= 1'b0;
                fb_valid <= 1'b1;
                fb_line  <= f_line;
                fb_data  <= rline;
            end
            // a store to sdram might hit the buffered line (self modifying code)
            if (p0_ack && p0_we)
                fb_valid <= 1'b0;
        end
    end

    // ---------------- bus ----------------
    wire [31:0]      p_awaddr, p_wdata, p_araddr;
    wire [3:0]       p_wstrb;
    wire [NS-1:0]    p_awvalid, p_awready, p_wvalid, p_wready, p_bvalid, p_bready;
    wire [NS-1:0]    p_arvalid, p_arready, p_rvalid, p_rready;
    wire [2*NS-1:0]  p_bresp, p_rresp;
    wire [32*NS-1:0] p_rdata;

    axil_xbar #(.NS(NS)) u_xbar (
        .clk(clk), .rst(io_rst),
        .s_awaddr(c_awaddr), .s_awvalid(c_awvalid), .s_awready(c_awready),
        .s_wdata(c_wdata), .s_wstrb(c_wstrb), .s_wvalid(c_wvalid), .s_wready(c_wready),
        .s_bresp(c_bresp), .s_bvalid(c_bvalid), .s_bready(c_bready),
        .s_araddr(c_araddr), .s_arvalid(c_arvalid), .s_arready(c_arready),
        .s_rdata(c_rdata), .s_rresp(c_rresp), .s_rvalid(c_rvalid), .s_rready(c_rready),
        .m_awaddr(p_awaddr), .m_awvalid(p_awvalid), .m_awready(p_awready),
        .m_wdata(p_wdata), .m_wstrb(p_wstrb), .m_wvalid(p_wvalid), .m_wready(p_wready),
        .m_bresp(p_bresp), .m_bvalid(p_bvalid), .m_bready(p_bready),
        .m_araddr(p_araddr), .m_arvalid(p_arvalid), .m_arready(p_arready),
        .m_rdata(p_rdata), .m_rresp(p_rresp), .m_rvalid(p_rvalid), .m_rready(p_rready)
    );

    // ---------------- peripherals ----------------
    uart_axi u_uart (
        .clk(clk), .rst(io_rst),
        .s_awaddr(p_awaddr), .s_awvalid(p_awvalid[0]), .s_awready(p_awready[0]),
        .s_wdata(p_wdata), .s_wstrb(p_wstrb), .s_wvalid(p_wvalid[0]), .s_wready(p_wready[0]),
        .s_bresp(p_bresp[1:0]), .s_bvalid(p_bvalid[0]), .s_bready(p_bready[0]),
        .s_araddr(p_araddr), .s_arvalid(p_arvalid[0]), .s_arready(p_arready[0]),
        .s_rdata(p_rdata[31:0]), .s_rresp(p_rresp[1:0]), .s_rvalid(p_rvalid[0]), .s_rready(p_rready[0]),
        .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready),
        .rx_data(rx_data), .rx_valid(rx_valid), .tx_idle(tx_idle)
    );

    timer_axi u_timer (
        .clk(clk), .rst(io_rst),
        .s_awaddr(p_awaddr), .s_awvalid(p_awvalid[1]), .s_awready(p_awready[1]),
        .s_wdata(p_wdata), .s_wstrb(p_wstrb), .s_wvalid(p_wvalid[1]), .s_wready(p_wready[1]),
        .s_bresp(p_bresp[3:2]), .s_bvalid(p_bvalid[1]), .s_bready(p_bready[1]),
        .s_araddr(p_araddr), .s_arvalid(p_arvalid[1]), .s_arready(p_arready[1]),
        .s_rdata(p_rdata[63:32]), .s_rresp(p_rresp[3:2]), .s_rvalid(p_rvalid[1]), .s_rready(p_rready[1]),
        .irq(irq_timer)
    );

    fft_axi u_fft (
        .clk(clk), .rst(io_rst),
        .s_awaddr(p_awaddr), .s_awvalid(p_awvalid[2]), .s_awready(p_awready[2]),
        .s_wdata(p_wdata), .s_wstrb(p_wstrb), .s_wvalid(p_wvalid[2]), .s_wready(p_wready[2]),
        .s_bresp(p_bresp[5:4]), .s_bvalid(p_bvalid[2]), .s_bready(p_bready[2]),
        .s_araddr(p_araddr), .s_arvalid(p_arvalid[2]), .s_arready(p_arready[2]),
        .s_rdata(p_rdata[95:64]), .s_rresp(p_rresp[5:4]), .s_rvalid(p_rvalid[2]), .s_rready(p_rready[2])
    );

    sys_axi #(.CLK_HZ(CLK_HZ)) u_sys (
        .clk(clk), .rst(io_rst),
        .s_awaddr(p_awaddr), .s_awvalid(p_awvalid[3]), .s_awready(p_awready[3]),
        .s_wdata(p_wdata), .s_wstrb(p_wstrb), .s_wvalid(p_wvalid[3]), .s_wready(p_wready[3]),
        .s_bresp(p_bresp[7:6]), .s_bvalid(p_bvalid[3]), .s_bready(p_bready[3]),
        .s_araddr(p_araddr), .s_arvalid(p_arvalid[3]), .s_arready(p_arready[3]),
        .s_rdata(p_rdata[127:96]), .s_rresp(p_rresp[7:6]), .s_rvalid(p_rvalid[3]), .s_rready(p_rready[3]),
        .led(led), .exit_valid(exit_valid), .exit_code(exit_code)
    );

    sdram_axi u_sdaxi (
        .clk(clk), .rst(io_rst),
        .s_awaddr(p_awaddr), .s_awvalid(p_awvalid[4]), .s_awready(p_awready[4]),
        .s_wdata(p_wdata), .s_wstrb(p_wstrb), .s_wvalid(p_wvalid[4]), .s_wready(p_wready[4]),
        .s_bresp(p_bresp[9:8]), .s_bvalid(p_bvalid[4]), .s_bready(p_bready[4]),
        .s_araddr(p_araddr), .s_arvalid(p_arvalid[4]), .s_arready(p_arready[4]),
        .s_rdata(p_rdata[159:128]), .s_rresp(p_rresp[9:8]), .s_rvalid(p_rvalid[4]), .s_rready(p_rready[4]),
        .req(a_req), .we(a_we), .addr(a_addr), .wdata(a_wdata), .wstrb(a_wstrb),
        .ack(p0_ack & ~cpu_rst), .rline(rline)
    );
endmodule
