// one byte lane of the main memory. true dual port: port a only reads (fetch),
// port b reads and writes (loads / stores, and the uart loader). both reads are
// sync, data comes out 1 clock after the address. gowin puts this in bsram.

module ram_lane #(
    parameter AW = 14
)(
    input  wire          clk,
    input  wire [AW-1:0] a_addr,
    output reg  [7:0]    a_rdata,
    input  wire [AW-1:0] b_addr,
    input  wire          b_we,
    input  wire [7:0]    b_wdata,
    output reg  [7:0]    b_rdata
);
    reg [7:0] mem [0:(1<<AW)-1];

    always @(posedge clk)
        a_rdata <= mem[a_addr];

    // write-through on port b (the only write mode gowin's dual port bsram has here).
    // nobody looks at b_rdata in the clock of a write anyway
    always @(posedge clk) begin
        if (b_we) begin
            mem[b_addr] <= b_wdata;
            b_rdata     <= b_wdata;
        end else
            b_rdata <= mem[b_addr];
    end
endmodule
