// rv32i + zicsr + zifencei decoder, pure combinational
// anything it doesn't know sets illegal

module rv_decode (
    input  wire [31:0] instr,
    output reg  [31:0] imm,
    output reg  [3:0]  alu_op,     // {sub/sra bit, funct3}
    output reg  [1:0]  a_sel,      // 0 rs1, 1 pc, 2 zero
    output reg         b_imm,      // alu b = imm instead of rs2
    output reg         rd_we,
    output reg         uses_rs1,
    output reg         uses_rs2,
    output reg         load,
    output reg         store,
    output reg         branch,
    output reg         jal,
    output reg         jalr,
    output reg         csr,
    output reg         ecall,
    output reg         ebreak,
    output reg         mret,
    output reg         fencei,
    output reg         illegal
);
    wire [6:0] op = instr[6:0];
    wire [2:0] f3 = instr[14:12];
    wire [6:0] f7 = instr[31:25];

    wire [31:0] imm_i = {{20{instr[31]}}, instr[31:20]};
    wire [31:0] imm_s = {{20{instr[31]}}, instr[31:25], instr[11:7]};
    wire [31:0] imm_b = {{19{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0};
    wire [31:0] imm_u = {instr[31:12], 12'd0};
    wire [31:0] imm_j = {{11{instr[31]}}, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0};

    always @(*) begin
        imm      = imm_i;
        alu_op   = 4'd0;            // add
        a_sel    = 2'd0;
        b_imm    = 1'b1;
        rd_we    = 1'b0;
        uses_rs1 = 1'b0;
        uses_rs2 = 1'b0;
        load     = 1'b0;
        store    = 1'b0;
        branch   = 1'b0;
        jal      = 1'b0;
        jalr     = 1'b0;
        csr      = 1'b0;
        ecall    = 1'b0;
        ebreak   = 1'b0;
        mret     = 1'b0;
        fencei   = 1'b0;
        illegal  = 1'b0;

        case (op)
            7'b0110111: begin       // lui: 0 + imm
                imm   = imm_u;
                a_sel = 2'd2;
                rd_we = 1'b1;
            end
            7'b0010111: begin       // auipc: pc + imm
                imm   = imm_u;
                a_sel = 2'd1;
                rd_we = 1'b1;
            end
            7'b1101111: begin       // jal
                imm   = imm_j;
                jal   = 1'b1;
                rd_we = 1'b1;
            end
            7'b1100111: begin       // jalr
                jalr     = 1'b1;
                rd_we    = 1'b1;
                uses_rs1 = 1'b1;
                illegal  = (f3 != 3'd0);
            end
            7'b1100011: begin       // beq bne blt bge bltu bgeu
                imm      = imm_b;
                branch   = 1'b1;
                uses_rs1 = 1'b1;
                uses_rs2 = 1'b1;
                illegal  = (f3 == 3'd2) || (f3 == 3'd3);
            end
            7'b0000011: begin       // lb lh lw lbu lhu
                load     = 1'b1;
                rd_we    = 1'b1;
                uses_rs1 = 1'b1;
                illegal  = (f3 == 3'd3) || (f3 == 3'd6) || (f3 == 3'd7);
            end
            7'b0100011: begin       // sb sh sw
                imm      = imm_s;
                store    = 1'b1;
                uses_rs1 = 1'b1;
                uses_rs2 = 1'b1;
                illegal  = (f3 > 3'd2);
            end
            7'b0010011: begin       // alu with immediate
                rd_we    = 1'b1;
                uses_rs1 = 1'b1;
                alu_op   = {1'b0, f3};
                if (f3 == 3'd1)
                    illegal = (f7 != 7'd0);                 // slli
                else if (f3 == 3'd5) begin
                    alu_op[3] = instr[30];                  // srli / srai
                    illegal   = (f7 != 7'd0) && (f7 != 7'b0100000);
                end
            end
            7'b0110011: begin       // alu reg reg
                rd_we    = 1'b1;
                uses_rs1 = 1'b1;
                uses_rs2 = 1'b1;
                b_imm    = 1'b0;
                alu_op   = {instr[30], f3};
                if (f7 == 7'b0100000)
                    illegal = (f3 != 3'd0) && (f3 != 3'd5);  // only sub and sra
                else
                    illegal = (f7 != 7'd0);
            end
            7'b0001111: begin       // fence = nop, fence.i = refetch
                fencei  = (f3 == 3'd1);
                illegal = (f3 > 3'd1);
            end
            7'b1110011: begin
                if (f3 == 3'd0) begin
                    case (instr)
                        32'h00000073: ecall  = 1'b1;
                        32'h00100073: ebreak = 1'b1;
                        32'h30200073: mret   = 1'b1;
                        32'h10500073: ;                     // wfi, just a nop here
                        default:      illegal = 1'b1;
                    endcase
                end else if (f3 == 3'd4)
                    illegal = 1'b1;
                else begin
                    csr      = 1'b1;
                    rd_we    = 1'b1;
                    uses_rs1 = ~f3[2];                      // csrrwi etc use the field as uimm
                end
            end
            default: illegal = 1'b1;
        endcase

        // nothing goes anywhere if it's illegal
        if (illegal) begin
            rd_we  = 1'b0;
            load   = 1'b0;
            store  = 1'b0;
            branch = 1'b0;
            jal    = 1'b0;
            jalr   = 1'b0;
            csr    = 1'b0;
            fencei = 1'b0;
        end
    end
endmodule
