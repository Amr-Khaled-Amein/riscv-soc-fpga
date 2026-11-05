// top level for the Tang Nano 20K: uart pins + loader + soc + the sdram in the chip
// talk to it with tools/soc_uart.py
//
// uart is 1 Mbaud (27 MHz / 27, exact), so loading the big compliance tests is quick
//
// leds (active low):
//   led[4:0]  whatever the program writes to the sys LED register
//   led[5]    cpu running

module top #(
    parameter CLKS_PER_BIT = 27,
    parameter RAM_AW       = 14,        // 64 KB block ram
    parameter TIMEOUT      = 2700000,
    parameter SD_INIT      = 6000
)(
    input  wire        clk,
    input  wire        uart_rxd,
    output wire        uart_txd,
    output wire [5:0]  led,

    // sdram inside the GW2AR-18, gowin wires these up by name
    output wire        O_sdram_clk,
    output wire        O_sdram_cke,
    output wire        O_sdram_cs_n,
    output wire        O_sdram_cas_n,
    output wire        O_sdram_ras_n,
    output wire        O_sdram_wen_n,
    output wire [3:0]  O_sdram_dqm,
    output wire [10:0] O_sdram_addr,
    output wire [1:0]  O_sdram_ba,
    inout  wire [31:0] IO_sdram_dq
);
    // power on reset, the regs come up as 0 on the gowin so this just counts up once
    reg [7:0] por_cnt = 8'd0;
    wire      por = ~&por_cnt;
    always @(posedge clk)
        if (por) por_cnt <= por_cnt + 8'd1;

    // ---------------- uart pins ----------------
    wire [7:0] rx_data, tx_data;
    wire       rx_valid, tx_valid, tx_ready;

    uart_rx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_rx (
        .clk(clk), .rst(por), .rxd(uart_rxd), .data(rx_data), .valid(rx_valid));

    uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_tx (
        .clk(clk), .rst(por), .data(tx_data), .valid(tx_valid), .ready(tx_ready), .txd(uart_txd));

    // ---------------- loader ----------------
    wire        run, cpu_rst, io_rst;
    wire [31:0] reset_pc, m_addr, m_rdata;
    wire [7:0]  m_wdata;
    wire        m_req, m_we, m_ack;
    wire [7:0]  h_tx_data, s_tx_data;
    wire        h_tx_valid, s_tx_valid, s_tx_idle;
    wire        exit_valid;
    wire [31:0] exit_code;
    wire [4:0]  sys_led;

    host_link #(.TIMEOUT(TIMEOUT)) u_host (
        .clk(clk), .rst(por),
        .rx_data(rx_data), .rx_valid(rx_valid & ~run),
        .tx_data(h_tx_data), .tx_valid(h_tx_valid), .tx_ready(tx_ready & ~run),
        .run(run), .cpu_rst(cpu_rst), .io_rst(io_rst), .reset_pc(reset_pc),
        .m_req(m_req), .m_we(m_we), .m_addr(m_addr), .m_wdata(m_wdata), .m_ack(m_ack), .m_rdata(m_rdata),
        .soc_tx_idle(s_tx_idle), .exit_valid(exit_valid), .exit_code(exit_code)
    );

    // the tx line belongs to the program while it runs, to the loader otherwise
    assign tx_data  = run ? s_tx_data  : h_tx_data;
    assign tx_valid = run ? s_tx_valid : h_tx_valid;

    // ---------------- soc ----------------
    soc #(.RAM_AW(RAM_AW), .SD_INIT(SD_INIT)) u_soc (
        .clk(clk), .rst(por), .cpu_rst(cpu_rst), .io_rst(io_rst), .reset_pc(reset_pc),
        .ld_req(m_req), .ld_we(m_we), .ld_addr(m_addr), .ld_wdata(m_wdata), .ld_ack(m_ack), .ld_rdata(m_rdata),
        .tx_data(s_tx_data), .tx_valid(s_tx_valid), .tx_ready(tx_ready & run),
        .rx_data(rx_data), .rx_valid(rx_valid & run), .tx_idle(s_tx_idle),
        .led(sys_led), .exit_valid(exit_valid), .exit_code(exit_code),
        .sd_clk(O_sdram_clk), .sd_cke(O_sdram_cke), .sd_cs_n(O_sdram_cs_n), .sd_ras_n(O_sdram_ras_n),
        .sd_cas_n(O_sdram_cas_n), .sd_we_n(O_sdram_wen_n), .sd_addr(O_sdram_addr), .sd_ba(O_sdram_ba),
        .sd_dqm(O_sdram_dqm), .sd_dq(IO_sdram_dq)
    );

    assign led = ~{run, sys_led};
endmodule
