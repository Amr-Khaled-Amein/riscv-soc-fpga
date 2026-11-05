// uart peripheral on axi4-lite, 16 byte fifo each way
//
//   0x0  TX    write: push a byte (dropped if full)   read: bit 31 = tx fifo full
//   0x4  RX    read: pop a byte, bit 31 = was empty (then the data is 0)
//   0x8  STAT  bit 0 tx full, bit 1 rx has data, bit 2 tx completely idle
//
// the bytes go to / come from uart_tx and uart_rx in the top level

module uart_axi (
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

    output wire [7:0]  tx_data,
    output wire        tx_valid,
    input  wire        tx_ready,
    input  wire [7:0]  rx_data,
    input  wire        rx_valid,
    output wire        tx_idle
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

    // tx fifo
    reg [7:0] txq [0:15];
    reg [4:0] tx_wp, tx_rp;
    wire      tx_empty = (tx_wp == tx_rp);
    wire      tx_full  = (tx_wp - tx_rp) == 5'd16;

    // rx fifo
    reg [7:0] rxq [0:15];
    reg [4:0] rx_wp, rx_rp;
    wire      rx_empty = (rx_wp == rx_rp);
    wire      rx_full  = (rx_wp - rx_rp) == 5'd16;

    assign tx_data  = txq[tx_rp[3:0]];
    assign tx_valid = ~tx_empty;
    assign tx_idle  = tx_empty & tx_ready;

    wire push_tx = wr_en & (wr_addr[3:2] == 2'd0) & wr_strb[0] & ~tx_full;
    wire pop_rx  = rd_en & (rd_addr[3:2] == 2'd1) & ~rx_empty;

    always @(posedge clk) begin
        if (rst) begin
            tx_wp <= 5'd0;
            tx_rp <= 5'd0;
            rx_wp <= 5'd0;
            rx_rp <= 5'd0;
        end else begin
            if (push_tx) begin
                txq[tx_wp[3:0]] <= wr_data[7:0];
                tx_wp <= tx_wp + 5'd1;
            end
            if (tx_valid && tx_ready)
                tx_rp <= tx_rp + 5'd1;
            if (rx_valid && !rx_full) begin
                rxq[rx_wp[3:0]] <= rx_data;
                rx_wp <= rx_wp + 5'd1;
            end
            if (pop_rx)
                rx_rp <= rx_rp + 5'd1;
        end
    end

    always @(posedge clk)
        if (rd_en)
            case (rd_addr[3:2])
                2'd0: rd_data <= {tx_full, 31'd0};
                2'd1: rd_data <= rx_empty ? 32'h8000_0000 : {24'd0, rxq[rx_rp[3:0]]};
                2'd2: rd_data <= {29'd0, tx_idle, ~rx_empty, tx_full};
                default: rd_data <= 32'd0;
            endcase
endmodule
