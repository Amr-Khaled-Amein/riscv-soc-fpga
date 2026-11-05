// uart loader / run control. this is what tools/soc_uart.py talks to.
// the cpu sits in reset until the pc says go.
//
// commands (numbers are big endian)
//   'P'                       -> 'o' 'k'
//   'W' addr(4) len(4) data   -> 'w' xor(data)          write bytes (block ram or sdram)
//   'R' addr(4) len(4)        -> 'r' data xor(data)     read bytes back
//   'G' pc(4) limit(4)        run from pc. limit = max clocks, 0 = forever
//
// while it runs, the uart belongs to the uart peripheral (printf etc). when the
// program writes the exit register (or hits the limit) the core is stopped, the tx
// fifo is let out, and then this comes back:
//   FF FF 'E' why(1) code(4) clocks(4)        why: 1 = exit, 2 = hit the limit
//
// a command that stops halfway for TIMEOUT clocks is dropped.

module host_link #(
    parameter TIMEOUT = 2700000         // ~100 ms
)(
    input  wire        clk,
    input  wire        rst,

    input  wire [7:0]  rx_data,
    input  wire        rx_valid,
    output reg  [7:0]  tx_data,
    output reg         tx_valid,
    input  wire        tx_ready,

    output wire        run,             // uart goes to the soc
    output wire        cpu_rst,
    output wire        io_rst,

    output reg  [31:0] reset_pc,

    // memory, one byte per request, req stays up until ack
    output reg         m_req,
    output reg         m_we,
    output reg  [31:0] m_addr,
    output reg  [7:0]  m_wdata,
    input  wire        m_ack,
    input  wire [31:0] m_rdata,

    input  wire        soc_tx_idle,
    input  wire        exit_valid,
    input  wire [31:0] exit_code
);
    localparam S_CMD = 4'd0, S_ARG = 4'd1, S_WDATA = 4'd2, S_WACK = 4'd3, S_RADDR = 4'd4,
               S_RWAIT = 4'd5, S_RSEND = 4'd6, S_REND = 4'd7, S_RUN = 4'd8, S_DRAIN = 4'd9,
               S_END = 4'd10, S_PING = 4'd11, S_WWAIT = 4'd12, S_GO = 4'd13;

    reg [3:0]  st;
    reg [7:0]  cmd;
    reg [63:0] arg;
    reg [3:0]  nleft;
    reg [31:0] addr, len, limit, clocks, code;
    reg [7:0]  xs;
    reg [3:0]  k;
    reg [7:0]  rbyte;
    reg [1:0]  why;
    reg [21:0] idle;

    assign run     = (st == S_RUN) || (st == S_DRAIN);
    assign cpu_rst = rst | (st != S_RUN);
    assign io_rst  = rst | ~run;

    wire [63:0] arg_n = {arg[55:0], rx_data};

    // what goes out in the reply states
    always @(*) begin
        tx_valid = 1'b0;
        tx_data  = 8'd0;
        case (st)
            S_PING:  begin tx_valid = 1'b1; tx_data = (k == 0) ? "o" : "k"; end
            S_WACK:  begin tx_valid = 1'b1; tx_data = (k == 0) ? "w" : xs; end
            S_RADDR: if (k == 0) begin tx_valid = 1'b1; tx_data = "r"; end
            S_RSEND: begin tx_valid = 1'b1; tx_data = rbyte; end
            S_REND:  begin tx_valid = 1'b1; tx_data = xs; end
            S_END: begin
                tx_valid = 1'b1;
                case (k)
                    4'd0, 4'd1: tx_data = 8'hff;
                    4'd2:  tx_data = "E";
                    4'd3:  tx_data = {6'd0, why};
                    4'd4:  tx_data = code[31:24];
                    4'd5:  tx_data = code[23:16];
                    4'd6:  tx_data = code[15:8];
                    4'd7:  tx_data = code[7:0];
                    4'd8:  tx_data = clocks[31:24];
                    4'd9:  tx_data = clocks[23:16];
                    4'd10: tx_data = clocks[15:8];
                    default: tx_data = clocks[7:0];
                endcase
            end
            default: ;
        endcase
    end

    wire sent = tx_valid & tx_ready;

    always @(posedge clk) begin
        if (rst) begin
            m_req <= 1'b0;
            st    <= S_CMD;
            k     <= 4'd0;
            idle  <= 22'd0;
            nleft <= 4'd0;
        end else begin
            // drop a half finished command
            if (st == S_ARG || st == S_WDATA) begin
                if (rx_valid)
                    idle <= 22'd0;
                else if (idle == TIMEOUT)
                    st <= S_CMD;
                else
                    idle <= idle + 22'd1;
            end else
                idle <= 22'd0;

            case (st)
                S_CMD: if (rx_valid) begin
                    cmd <= rx_data;
                    k   <= 4'd0;
                    case (rx_data)
                        "W", "R", "G": begin st <= S_ARG; nleft <= 4'd8; end
                        "P":      st <= S_PING;
                        default:  ;
                    endcase
                end

                S_ARG: if (rx_valid) begin
                    arg   <= arg_n;
                    nleft <= nleft - 4'd1;
                    if (nleft == 4'd1) begin
                        xs <= 8'd0;
                        if (cmd == "G") begin
                            reset_pc <= arg_n[63:32];
                            limit    <= arg_n[31:0];
                            clocks   <= 32'd0;
                            st       <= S_GO;
                        end else begin
                            addr <= arg_n[63:32];
                            len  <= arg_n[31:0];
                            if (arg_n[31:0] == 32'd0)
                                st <= (cmd == "W") ? S_WACK : S_RADDR;
                            else
                                st <= (cmd == "W") ? S_WDATA : S_RADDR;
                        end
                    end
                end

                S_WDATA: if (rx_valid) begin
                    m_req   <= 1'b1;
                    m_we    <= 1'b1;
                    m_addr  <= addr;
                    m_wdata <= rx_data;
                    xs      <= xs ^ rx_data;
                    st      <= S_WWAIT;
                end
                S_WWAIT: if (m_ack) begin
                    m_req <= 1'b0;
                    addr  <= addr + 32'd1;
                    len   <= len - 32'd1;
                    st    <= (len == 32'd1) ? S_WACK : S_WDATA;
                end

                S_WACK: if (sent) begin
                    k <= k + 4'd1;
                    if (k == 4'd1) st <= S_CMD;
                end

                // 'r' goes out first (k = 0), then one byte per address
                S_RADDR: if (k != 0 || sent) begin
                    k <= 4'd1;
                    if (len == 32'd0)
                        st <= S_REND;
                    else begin
                        m_req  <= 1'b1;
                        m_we   <= 1'b0;
                        m_addr <= addr;
                        st     <= S_RWAIT;
                    end
                end
                S_RWAIT: if (m_ack) begin
                    m_req <= 1'b0;
                    rbyte <= m_rdata[8*addr[1:0] +: 8];
                    st    <= S_RSEND;
                end
                S_RSEND: if (sent) begin
                    xs   <= xs ^ rbyte;
                    addr <= addr + 32'd1;
                    len  <= len - 32'd1;
                    st   <= (len == 32'd1) ? S_REND : S_RADDR;
                end
                S_REND: if (sent) st <= S_CMD;

                // one more clock in reset so the core picks up the new reset_pc
                S_GO: st <= S_RUN;

                S_RUN: begin
                    clocks <= clocks + 32'd1;
                    if (exit_valid) begin
                        why  <= 2'd1;
                        code <= exit_code;
                        st   <= S_DRAIN;
                    end else if (limit != 32'd0 && clocks == limit - 32'd1) begin
                        why  <= 2'd2;
                        code <= 32'd0;
                        st   <= S_DRAIN;
                    end
                end
                // core is stopped, wait for the printf output to finish
                S_DRAIN: if (soc_tx_idle) begin
                    k  <= 4'd0;
                    st <= S_END;
                end
                S_END: if (sent) begin
                    k <= k + 4'd1;
                    if (k == 4'd11) st <= S_CMD;
                end
                S_PING: if (sent) begin
                    k <= k + 4'd1;
                    if (k == 4'd1) st <= S_CMD;
                end
                default: st <= S_CMD;
            endcase
        end
    end
endmodule
