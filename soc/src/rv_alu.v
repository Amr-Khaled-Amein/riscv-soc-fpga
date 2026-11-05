// op = {instr[30], funct3} for the reg-reg ops, so decode is mostly a copy

module rv_alu (
    input  wire [31:0] a,
    input  wire [31:0] b,
    input  wire [3:0]  op,
    output reg  [31:0] y
);
    wire [4:0] sh = b[4:0];

    always @(*) begin
        case (op)
            4'b0000: y = a + b;
            4'b1000: y = a - b;
            4'b0001, 4'b1001: y = a << sh;
            4'b0010, 4'b1010: y = {31'd0, $signed(a) < $signed(b)};
            4'b0011, 4'b1011: y = {31'd0, a < b};
            4'b0100, 4'b1100: y = a ^ b;
            4'b0101: y = a >> sh;
            4'b1101: y = $signed(a) >>> sh;
            4'b0110, 4'b1110: y = a | b;
            default: y = a & b;
        endcase
    end
endmodule
