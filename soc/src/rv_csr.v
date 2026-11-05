// machine mode csrs (m-mode only, no u/s mode)
//
// mstatus (MIE, MPIE, MPP fixed at 3), misa, mie/mip (timer only), mtvec (direct),
// mscratch, mepc, mcause, mtval, the id regs, mcycle/minstret + user aliases,
// mcountinhibit. hpm counters/events exist but read 0.
// a write to a read only csr or to anything not in the list is illegal.
//
// everything here happens in EX. 'go' says the instruction in EX really moves on
// this clock, so writes and traps only land once.

module rv_csr (
    input  wire        clk,
    input  wire        rst,
    input  wire        go,

    // csr instruction in EX
    input  wire        en,
    input  wire [11:0] addr,
    input  wire [2:0]  f3,
    input  wire [4:0]  rs1_f,      // rs1 field (also the uimm)
    input  wire [31:0] rs1_val,
    output reg  [31:0] rdata,
    output wire        illegal,

    // trap / mret from EX
    input  wire        trap,
    input  wire [31:0] cause,
    input  wire [31:0] epc,
    input  wire [31:0] tval,
    input  wire        mret,
    input  wire        retire,     // one instruction finished (for minstret)

    input  wire        irq_timer,
    output wire        irq,        // take the timer interrupt
    output wire [31:0] mtvec_o,
    output wire [31:0] mepc_o
);
    reg        mie_b, mpie_b;      // mstatus bits
    reg        mtie;
    reg [31:0] mtvec, mscratch, mepc, mcause, mtval;
    reg [63:0] mcycle, minstret;
    reg        inh_cy, inh_ir;     // mcountinhibit

    assign mtvec_o = mtvec;
    assign mepc_o  = mepc;
    assign irq     = mie_b & mtie & irq_timer;

    wire [31:0] mstatus = {19'd0, 2'b11, 3'd0, mpie_b, 3'd0, mie_b, 3'd0};

    // known csrs, and which of them can't be written
    reg known;
    always @(*) begin
        known = 1'b1;
        rdata = 32'd0;
        casez (addr)
            12'h300: rdata = mstatus;
            12'h310: rdata = 32'd0;                 // mstatush
            12'h301: rdata = 32'h40000100;          // rv32 + I
            12'h304: rdata = {24'd0, mtie, 7'd0};
            12'h344: rdata = {24'd0, irq_timer, 7'd0};
            12'h305: rdata = mtvec;
            12'h340: rdata = mscratch;
            12'h341: rdata = mepc;
            12'h342: rdata = mcause;
            12'h343: rdata = mtval;
            12'h320: rdata = {29'd0, inh_ir, 1'b0, inh_cy};
            12'hf11, 12'hf12, 12'hf13, 12'hf14, 12'hf15: rdata = 32'd0;
            12'hb00, 12'hc00: rdata = mcycle[31:0];
            12'hb80, 12'hc80: rdata = mcycle[63:32];
            12'hb02, 12'hc02: rdata = minstret[31:0];
            12'hb82, 12'hc82: rdata = minstret[63:32];
            default: begin
                // mhpmcounter3..31(h) and mhpmevent3..31 are there but stuck at 0
                if ((addr >= 12'hb03 && addr <= 12'hb1f) || (addr >= 12'hb83 && addr <= 12'hb9f) ||
                    (addr >= 12'h323 && addr <= 12'h33f))
                    rdata = 32'd0;
                else
                    known = 1'b0;
            end
        endcase
    end

    // csrrw(i) always writes, csrrs/c(i) only when the rs1 field isn't 0
    wire        wr   = (f3[1:0] == 2'b01) || (rs1_f != 5'd0);
    wire [31:0] src  = f3[2] ? {27'd0, rs1_f} : rs1_val;
    wire [31:0] wval = (f3[1:0] == 2'b01) ? src :
                       (f3[1:0] == 2'b10) ? (rdata | src) : (rdata & ~src);

    assign illegal = en & (~known | (wr & (addr[11:10] == 2'b11)));

    wire we = go & en & wr & ~illegal & ~trap;

    always @(posedge clk) begin
        if (rst) begin
            mie_b    <= 1'b0;
            mpie_b   <= 1'b0;
            mtie     <= 1'b0;
            mtvec    <= 32'd0;
            mscratch <= 32'd0;
            mepc     <= 32'd0;
            mcause   <= 32'd0;
            mtval    <= 32'd0;
            mcycle   <= 64'd0;
            minstret <= 64'd0;
            inh_cy   <= 1'b0;
            inh_ir   <= 1'b0;
        end else begin
            if (!inh_cy)
                mcycle <= mcycle + 64'd1;
            if (go && retire && !inh_ir)
                minstret <= minstret + 64'd1;

            if (go && trap) begin
                mepc   <= {epc[31:2], 2'b00};
                mcause <= cause;
                mtval  <= tval;
                mpie_b <= mie_b;
                mie_b  <= 1'b0;
            end else if (go && mret) begin
                mie_b  <= mpie_b;
                mpie_b <= 1'b1;
            end

            // a csr write wins over the counter going up in the same clock
            if (we) begin
                case (addr)
                    12'h300: begin mie_b <= wval[3]; mpie_b <= wval[7]; end
                    12'h304: mtie     <= wval[7];
                    12'h305: mtvec    <= {wval[31:2], 2'b00};
                    12'h340: mscratch <= wval;
                    12'h341: mepc     <= {wval[31:2], 2'b00};
                    12'h342: mcause   <= wval;
                    12'h343: mtval    <= wval;
                    12'h320: begin inh_cy <= wval[0]; inh_ir <= wval[2]; end
                    12'hb00: mcycle[31:0]    <= wval;
                    12'hb80: mcycle[63:32]   <= wval;
                    12'hb02: minstret[31:0]  <= wval;
                    12'hb82: minstret[63:32] <= wval;
                    default: ;
                endcase
            end
        end
    end
endmodule
