// 5 stage pipelined rv32i core: IF ID EX MEM WB
//
// memory is block ram with a sync read, so
//   IF   the next pc goes to the instruction ram, instr comes out at the start of ID
//   ID   decode, regfile read, jal and backward branches redirect fetch right here
//   EX   alu, branch check, csr, traps. loads/stores put their address on the data ram
//        here, stores write on this clock edge
//   MEM  load data comes out of the ram. io accesses go out on axi4-lite and the
//        whole pipeline waits for the answer
//   WB   regfile write
//
// notes
//  - jal and backward branches are taken in ID (no bubble). a branch that went the
//    other way, jalr, traps, mret and fence.i redirect from EX and cost 1 bubble
//  - forwarding from MEM and WB into EX, WB -> ID through the regfile
//  - load-use = 1 stall
//  - everything that can't be undone (store, csr write, trap) happens in EX, so
//    nothing older can still trap behind it. that makes traps precise for free
//  - misaligned loads/stores/jumps trap, so does any address outside ram, sdram and io
//  - code can run from sdram too, it's just slower (see fetch in soc.v)

module rv_core #(
    parameter RAM_AW = 14                   // block ram size in words = 2^RAM_AW
)(
    input  wire        clk,
    input  wire        rst,
    input  wire [31:0] reset_pc,

    // instruction fetch. data shows up 1 clock after the address, or later if
    // i_wait is high (sdram). i_wait says the instruction for the address of the
    // last clock isn't there yet
    output wire [31:0] i_addr,
    input  wire [31:0] i_rdata,
    input  wire        i_wait,

    // data ram, same timing. d_we = byte enables
    output wire [31:0] d_addr,
    output wire [3:0]  d_we,
    output wire [31:0] d_wdata,
    input  wire [31:0] d_rdata,

    // axi4-lite master for io (0x1000_0000 - 0x1000_3fff) and the sdram (0x8000_0000 - 0x807f_ffff)
    output wire [31:0] m_awaddr,
    output wire        m_awvalid,
    input  wire        m_awready,
    output wire [31:0] m_wdata,
    output wire [3:0]  m_wstrb,
    output wire        m_wvalid,
    input  wire        m_wready,
    input  wire [1:0]  m_bresp,
    input  wire        m_bvalid,
    output wire        m_bready,
    output wire [31:0] m_araddr,
    output wire        m_arvalid,
    input  wire        m_arready,
    input  wire [31:0] m_rdata,
    input  wire [1:0]  m_rresp,
    input  wire        m_rvalid,
    output wire        m_rready,

    input  wire        irq_timer
);
    function in_ram;
        input [31:0] a;
        in_ram = (a[31:RAM_AW+2] == 0);
    endfunction

    // 4 peripherals, 4 KB each
    function in_io;
        input [31:0] a;
        in_io = (a[31:14] == 18'h04000);
    endfunction

    // 8 MB sdram
    function in_sd;
        input [31:0] a;
        in_sd = (a[31:23] == 9'h100);
    endfunction

    // ---------------- pipeline registers ----------------

    // ID (the instruction itself is i_rdata)
    reg  [31:0] id_pc;

    // ID/EX
    reg  [31:0] ex_pc, ex_instr, ex_imm, ex_rs1_val, ex_rs2_val;
    reg  [4:0]  ex_rs1, ex_rd;
    reg  [3:0]  ex_alu_op;
    reg  [1:0]  ex_a_sel;
    reg         ex_valid, ex_b_imm, ex_rd_we, ex_load, ex_store, ex_branch, ex_jal, ex_jalr;
    reg         ex_csr, ex_ecall, ex_ebreak, ex_mret, ex_fencei, ex_illegal, ex_ifault, ex_pred;
    reg         ex_fa_mem, ex_fa_wb, ex_fb_mem, ex_fb_wb;    // forwarding, decided in ID

    // EX/MEM
    reg  [31:0] mem_pc, mem_instr, mem_result, mem_wdata, mem_cause;
    reg  [4:0]  mem_rd;
    reg  [3:0]  mem_strb;
    reg  [2:0]  mem_f3;
    reg         mem_valid, mem_rd_we, mem_load, mem_store, mem_io, mem_trap;

    // MEM/WB
    reg  [31:0] wb_pc, wb_instr, wb_result, wb_wdata, wb_cause, wb_io_rdata;
    reg  [4:0]  wb_rd;
    reg  [3:0]  wb_strb;
    reg         wb_valid, wb_rd_we, wb_store, wb_load, wb_io, wb_trap;

    // stall / flush control, driven further down
    wire        freeze;             // io access in MEM, nothing moves
    wire        stall;              // load-use, hold ID and put a bubble in EX
    wire        ex_redirect;
    wire [31:0] ex_target;
    wire        id_redirect;
    wire [31:0] id_target;
    wire [31:0] wb_data;
    wire        ex_go = ex_valid & ~freeze;

    // ======================= IF =======================
    // freeze/stall just read the same instruction again
    assign i_addr = rst              ? reset_pc  :
                    freeze           ? id_pc     :
                    ex_redirect      ? ex_target :
                    (stall | i_wait) ? id_pc     :
                    id_redirect      ? id_target : id_pc + 32'd4;

    always @(posedge clk)
        id_pc <= i_addr;

    // ======================= ID =======================
    wire [31:0] id_instr = i_rdata;
    wire [4:0]  id_rs1 = id_instr[19:15];
    wire [4:0]  id_rs2 = id_instr[24:20];
    wire [4:0]  id_rd  = id_instr[11:7];

    wire [31:0] d_imm;
    wire [3:0]  d_alu_op;
    wire [1:0]  d_a_sel;
    wire        d_b_imm, d_rd_we, d_uses_rs1, d_uses_rs2, d_load, d_store, d_branch, d_jal, d_jalr;
    wire        d_csr, d_ecall, d_ebreak, d_mret, d_fencei, d_illegal;

    rv_decode u_dec (
        .instr(id_instr), .imm(d_imm), .alu_op(d_alu_op), .a_sel(d_a_sel), .b_imm(d_b_imm),
        .rd_we(d_rd_we), .uses_rs1(d_uses_rs1), .uses_rs2(d_uses_rs2), .load(d_load), .store(d_store),
        .branch(d_branch), .jal(d_jal), .jalr(d_jalr), .csr(d_csr), .ecall(d_ecall), .ebreak(d_ebreak),
        .mret(d_mret), .fencei(d_fencei), .illegal(d_illegal)
    );

    // regfile, x0 is never written. writes in WB show up in ID the same clock
    reg  [31:0] rf [1:31] /* synthesis syn_ramstyle = "registers" */;
    wire        wb_we = wb_valid & wb_rd_we & (wb_rd != 5'd0);

    always @(posedge clk)
        if (wb_we) rf[wb_rd] <= wb_data;

    wire [31:0] id_rs1_val = (id_rs1 == 5'd0) ? 32'd0 :
                             (wb_we && wb_rd == id_rs1) ? wb_data : rf[id_rs1];
    wire [31:0] id_rs2_val = (id_rs2 == 5'd0) ? 32'd0 :
                             (wb_we && wb_rd == id_rs2) ? wb_data : rf[id_rs2];

    // fetching from outside ram / sdram
    wire id_ifault = ~in_ram(id_pc) & ~in_sd(id_pc);

    // static prediction: jal always, branches only backwards (loops).
    // a misaligned target isn't followed, EX traps on it instead
    assign id_target   = id_pc + d_imm;
    wire   id_pred     = ~i_wait & ~id_ifault & (d_jal | (d_branch & d_imm[31])) & ~id_target[1];
    assign id_redirect = id_pred;

    // forwarding is worked out here and registered, so EX only has a mux left.
    // whatever is in EX / MEM now is in MEM / WB when this instruction gets to EX
    wire fa_mem = ex_valid & ex_rd_we & (ex_rd != 5'd0) & (ex_rd == id_rs1);
    wire fb_mem = ex_valid & ex_rd_we & (ex_rd != 5'd0) & (ex_rd == id_rs2);
    wire fa_wb  = mem_valid & mem_rd_we & (mem_rd != 5'd0) & (mem_rd == id_rs1);
    wire fb_wb  = mem_valid & mem_rd_we & (mem_rd != 5'd0) & (mem_rd == id_rs2);

    // load in EX and we need its result -> wait a clock
    assign stall = ex_valid & ex_load & (ex_rd != 5'd0) &
                   ((d_uses_rs1 & (id_rs1 == ex_rd)) | (d_uses_rs2 & (id_rs2 == ex_rd)));

    always @(posedge clk) begin
        if (rst || (!freeze && (ex_redirect || stall || i_wait))) begin
            ex_valid  <= 1'b0;
            ex_rd_we  <= 1'b0;
            ex_load   <= 1'b0;
            ex_store  <= 1'b0;
            ex_branch <= 1'b0;
            ex_jal    <= 1'b0;
            ex_jalr   <= 1'b0;
            ex_csr    <= 1'b0;
            ex_ecall  <= 1'b0;
            ex_ebreak <= 1'b0;
            ex_mret   <= 1'b0;
            ex_fencei <= 1'b0;
            ex_illegal <= 1'b0;
            ex_ifault <= 1'b0;
            ex_pred   <= 1'b0;
        end else if (!freeze) begin
            ex_valid   <= 1'b1;
            ex_pc      <= id_pc;
            ex_instr   <= id_instr;
            ex_imm     <= d_imm;
            ex_rs1     <= id_rs1;
            ex_rd      <= id_rd;
            ex_rs1_val <= id_rs1_val;
            ex_rs2_val <= id_rs2_val;
            ex_alu_op  <= d_alu_op;
            ex_a_sel   <= d_a_sel;
            ex_b_imm   <= d_b_imm;
            ex_rd_we   <= d_rd_we & ~id_ifault;
            ex_load    <= d_load & ~id_ifault;
            ex_store   <= d_store & ~id_ifault;
            ex_branch  <= d_branch & ~id_ifault;
            ex_jal     <= d_jal & ~id_ifault;
            ex_jalr    <= d_jalr & ~id_ifault;
            ex_csr     <= d_csr & ~id_ifault;
            ex_ecall   <= d_ecall & ~id_ifault;
            ex_ebreak  <= d_ebreak & ~id_ifault;
            ex_mret    <= d_mret & ~id_ifault;
            ex_fencei  <= d_fencei & ~id_ifault;
            ex_illegal <= d_illegal & ~id_ifault;
            ex_ifault  <= id_ifault;
            ex_pred    <= id_pred;
            ex_fa_mem  <= fa_mem;
            ex_fb_mem  <= fb_mem;
            ex_fa_wb   <= fa_wb;
            ex_fb_wb   <= fb_wb;
        end
    end

    // ======================= EX =======================
    // forwarding, MEM first (newer). a load in MEM can't be needed here, that stalled.
    // a trapped instruction in MEM / WB doesn't write, so it can't be forwarded
    wire fwd_a_mem = ex_fa_mem & mem_rd_we;
    wire fwd_b_mem = ex_fb_mem & mem_rd_we;
    wire fwd_a_wb  = ex_fa_wb & wb_rd_we;
    wire fwd_b_wb  = ex_fb_wb & wb_rd_we;

    wire [31:0] rs1_v = fwd_a_mem ? mem_result : fwd_a_wb ? wb_data : ex_rs1_val;
    wire [31:0] rs2_v = fwd_b_mem ? mem_result : fwd_b_wb ? wb_data : ex_rs2_val;

    wire [31:0] alu_a = (ex_a_sel == 2'd1) ? ex_pc : (ex_a_sel == 2'd2) ? 32'd0 : rs1_v;
    wire [31:0] alu_b = ex_b_imm ? ex_imm : rs2_v;
    wire [31:0] alu_y;

    rv_alu u_alu (.a(alu_a), .b(alu_b), .op(ex_alu_op), .y(alu_y));

    // branches
    wire [2:0] f3 = ex_instr[14:12];
    wire eq  = (rs1_v == rs2_v);
    wire lt  = ($signed(rs1_v) < $signed(rs2_v));
    wire ltu = (rs1_v < rs2_v);
    reg  cond;
    always @(*)
        case (f3)
            3'd0: cond = eq;
            3'd1: cond = ~eq;
            3'd4: cond = lt;
            3'd5: cond = ~lt;
            3'd6: cond = ltu;
            default: cond = ~ltu;
        endcase

    // loads / stores have their own adder, it's on the path to the ram address
    wire [31:0] addr = rs1_v + ex_imm;

    wire        take    = ex_jal | ex_jalr | (ex_branch & cond);
    wire [31:0] jtarget = ex_jalr ? {addr[31:1], 1'b0} : (ex_pc + ex_imm);
    wire [31:0] pc4     = ex_pc + 32'd4;

    wire misal = (f3[1:0] == 2'd1 & addr[0]) | (f3[1:0] == 2'd2 & addr[1:0] != 2'd0);
    wire a_ram = in_ram(addr);
    wire a_bus = in_io(addr) | in_sd(addr);     // goes out on axi

    reg [3:0]  strb;
    reg [31:0] wdata;
    always @(*)
        case (f3[1:0])
            2'd0: begin strb = 4'b0001 << addr[1:0];        wdata = {4{rs2_v[7:0]}}; end
            2'd1: begin strb = addr[1] ? 4'b1100 : 4'b0011; wdata = {2{rs2_v[15:0]}}; end
            default: begin strb = 4'b1111;                  wdata = rs2_v; end
        endcase

    // csr
    wire [31:0] csr_rdata, mtvec, mepc;
    wire        csr_illegal, irq;
    reg         exc;
    reg  [31:0] exc_cause, exc_tval;

    // exceptions, highest priority first
    always @(*) begin
        exc       = 1'b1;
        exc_cause = 32'd0;
        exc_tval  = 32'd0;
        if (ex_ifault) begin
            exc_cause = 32'd1;  exc_tval = ex_pc;
        end else if (ex_illegal || csr_illegal) begin
            exc_cause = 32'd2;  exc_tval = ex_instr;
        end else if (ex_ecall) begin
            exc_cause = 32'd11;
        end else if (ex_ebreak) begin
            exc_cause = 32'd3;  exc_tval = ex_pc;
        end else if (take && jtarget[1]) begin
            exc_cause = 32'd0;  exc_tval = jtarget;
        end else if (ex_load && misal) begin
            exc_cause = 32'd4;  exc_tval = addr;
        end else if (ex_load && !a_ram && !a_bus) begin
            exc_cause = 32'd5;  exc_tval = addr;
        end else if (ex_store && misal) begin
            exc_cause = 32'd6;  exc_tval = addr;
        end else if (ex_store && !a_ram && !a_bus) begin
            exc_cause = 32'd7;  exc_tval = addr;
        end else
            exc = 1'b0;
    end

    // an interrupt goes in front of whatever is in EX, that one runs again after mret
    wire        trap  = ex_valid & (irq | exc);
    wire [31:0] cause = irq ? 32'h8000_0007 : exc_cause;

    rv_csr u_csr (
        .clk(clk), .rst(rst), .go(ex_go),
        .en(ex_valid & ex_csr), .addr(ex_instr[31:20]), .f3(f3), .rs1_f(ex_rs1), .rs1_val(rs1_v),
        .rdata(csr_rdata), .illegal(csr_illegal),
        .trap(trap), .cause(cause), .epc(ex_pc), .tval(irq ? 32'd0 : exc_tval),
        .mret(ex_mret), .retire(~trap),
        .irq_timer(irq_timer), .irq(irq), .mtvec_o(mtvec), .mepc_o(mepc)
    );

    assign ex_redirect = ex_go & (trap | ex_mret | ex_fencei | (take != ex_pred));
    assign ex_target   = trap      ? mtvec :
                         ex_mret   ? mepc  :
                         ex_fencei ? pc4   :
                         take      ? jtarget : pc4;

    wire [31:0] ex_result = (ex_jal | ex_jalr) ? pc4 : ex_csr ? csr_rdata : alu_y;

    // data ram: address every clock, stores write only when they really happen
    wire st_ram = ex_go & ex_store & ~trap & a_ram;
    assign d_addr  = addr;
    assign d_we    = st_ram ? strb : 4'd0;
    assign d_wdata = wdata;

    always @(posedge clk) begin
        if (rst) begin
            mem_valid <= 1'b0;
            mem_rd_we <= 1'b0;
            mem_load  <= 1'b0;
            mem_store <= 1'b0;
            mem_io    <= 1'b0;
            mem_trap  <= 1'b0;
        end else if (!freeze) begin
            // a trapped instruction keeps going as a marker (for the trace), doing nothing
            mem_valid  <= ex_valid;
            mem_trap   <= trap;
            mem_rd_we  <= ex_rd_we & ~trap;
            mem_load   <= ex_load & ~trap;
            mem_store  <= ex_store & ~trap;
            mem_io     <= (ex_load | ex_store) & ~trap & a_bus;
            mem_pc     <= ex_pc;
            mem_instr  <= ex_instr;
            mem_rd     <= ex_rd;
            mem_result <= ex_result;
            mem_wdata  <= wdata;
            mem_strb   <= strb;
            mem_f3     <= f3;
            mem_cause  <= cause;
        end
    end

    // ======================= MEM =======================
    // io / sdram: one axi transaction, the pipeline is frozen until the answer is back
    reg        aw_ok, w_ok, ar_ok, io_done;
    reg [31:0] io_rdata;

    wire io_wr = mem_valid & mem_io & mem_store;
    wire io_rd = mem_valid & mem_io & mem_load;
    assign freeze = (io_wr | io_rd) & ~io_done;

    assign m_awaddr  = mem_result;
    assign m_awvalid = io_wr & ~io_done & ~aw_ok;
    assign m_wdata   = mem_wdata;
    assign m_wstrb   = mem_strb;
    assign m_wvalid  = io_wr & ~io_done & ~w_ok;
    assign m_bready  = 1'b1;
    assign m_araddr  = mem_result;
    assign m_arvalid = io_rd & ~io_done & ~ar_ok;
    assign m_rready  = 1'b1;

    always @(posedge clk) begin
        if (rst || !freeze) begin
            aw_ok   <= 1'b0;
            w_ok    <= 1'b0;
            ar_ok   <= 1'b0;
            io_done <= 1'b0;
        end else begin
            if (m_awvalid && m_awready) aw_ok <= 1'b1;
            if (m_wvalid && m_wready)   w_ok  <= 1'b1;
            if (m_arvalid && m_arready) ar_ok <= 1'b1;
            if (m_bvalid && io_wr)      io_done <= 1'b1;
            if (m_rvalid && io_rd) begin
                io_done  <= 1'b1;
                io_rdata <= m_rdata;
            end
        end
    end

    // load alignment + sign extension
    wire [31:0] raw = mem_io ? io_rdata : d_rdata;
    wire [31:0] sh  = raw >> {mem_result[1:0], 3'b000};
    reg  [31:0] ld;
    always @(*)
        case (mem_f3)
            3'd0: ld = {{24{sh[7]}}, sh[7:0]};
            3'd1: ld = {{16{sh[15]}}, sh[15:0]};
            3'd4: ld = {24'd0, sh[7:0]};
            3'd5: ld = {16'd0, sh[15:0]};
            default: ld = raw;
        endcase

    always @(posedge clk) begin
        if (rst) begin
            wb_valid <= 1'b0;
            wb_rd_we <= 1'b0;
            wb_load  <= 1'b0;
            wb_store <= 1'b0;
            wb_io    <= 1'b0;
            wb_trap  <= 1'b0;
        end else if (!freeze) begin
            wb_valid    <= mem_valid;
            wb_rd_we    <= mem_rd_we;
            wb_load     <= mem_load;
            wb_store    <= mem_store;
            wb_io       <= mem_io;
            wb_trap     <= mem_trap;
            wb_rd       <= mem_rd;
            wb_result   <= mem_load ? ld : mem_result;
            wb_pc       <= mem_pc;
            wb_instr    <= mem_instr;
            wb_wdata    <= mem_wdata;
            wb_strb     <= mem_strb;
            wb_cause    <= mem_cause;
            wb_io_rdata <= io_rdata;
        end
    end

    // ======================= WB =======================
    assign wb_data = wb_result;
endmodule
