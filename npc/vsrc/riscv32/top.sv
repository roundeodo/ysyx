module top
  import riscv32_pkg::*;
#(
    parameter DATA_WIDTH = 32,
    parameter ADDR_WIDTH = 5
) (
    input logic clk,
    input logic rstn
);
  // top is only the structural connection layer. It should pass decoded control
  // and execution result records between modules, not repeat ISA decode here.
  decode_ctrl_t w_decode_ctrl;

  // C2 has no commit/trap stage yet, so these control metadata bits are
  // intentionally produced by Decoder but not consumed by top.
  // Future pipeline/OoO designs should carry them to commit/retire.
  /* verilator lint_off UNUSEDSIGNAL */
  logic unused_ctrl_metadata;
  assign unused_ctrl_metadata = ^{w_decode_ctrl.valid, w_decode_ctrl.illegal_instr, w_decode_ctrl.exception_cause};
  /* verilator lint_on UNUSEDSIGNAL */

  //IFU TO IDU
  logic [DATA_WIDTH-1:0] w_pc;
  logic [DATA_WIDTH-1:0] w_instruction;

  // IDU to Ctrl & EXU
  logic [6:0] w_opcode;
  logic [2:0] w_funct_3;
  logic [6:0] w_funct_7;
  logic [4:0] w_rd_addr;
  logic [4:0] w_rs1_addr;
  logic [4:0] w_rs2_addr;
  logic [31:0] w_imm_I, w_imm_S, w_imm_U;
  logic        [          11:0] w_funct_12;
  logic        [          31:0] w_imm_B;
  logic        [          31:0] w_imm_J;

  // RF to EXU
  logic        [DATA_WIDTH-1:0] w_rs1_data;
  logic        [DATA_WIDTH-1:0] w_rs2_data;

  // EXU to LSU & IFU
  // ex_result_t is the single execution-result record produced by EXU.
  // Keep top as a connection layer: pass fields or the whole record forward,
  // but do not recreate old w_ex_* scattered wires.
  ex_result_t                   w_ex_result;

  // LSU to WBU
  // lsu_result_t is the LSU completion record consumed by WBU.
  // Future bypass, writeback arbitration, and ROB completion should consume
  // this record instead of reconstructing result metadata from top-level wires.
  lsu_result_t                  w_lsu_result;

  // WBU to RegFile
  logic        [DATA_WIDTH-1:0] w_wbu_wdata;
  logic        [           4:0] w_wbu_waddr;
  logic                         w_wbu_wen;

  // imm Mux to EXU
  logic        [DATA_WIDTH-1:0] w_imm_final;

  // CSR related
  logic        [          31:0] w_csr_rdata;
  logic        [          31:0] w_csr_mtvec;
  logic        [          31:0] w_csr_mepc;
  logic                         w_csr_illegal;

  /* verilator lint_off UNUSEDSIGNAL */
  logic                         unused_csr_status;
  assign unused_csr_status = w_csr_illegal;
  /* verilator lint_on UNUSEDSIGNAL */

  logic                         w_redirect_valid;
  logic        [          31:0] w_redirect_pc;


  always_comb begin
    // Immediate mux uses Decoder output, not opcode decode in top.
    // This keeps ISA decode centralized in Decoder and lets future ID/EX
    // or dispatch-stage uop control carry imm_sel as metadata.
    case (w_decode_ctrl.imm_sel)
      IMM_NONE: w_imm_final = 32'b0;
      IMM_I:    w_imm_final = w_imm_I;
      IMM_S:    w_imm_final = w_imm_S;
      IMM_B:    w_imm_final = w_imm_B;
      IMM_U:    w_imm_final = w_imm_U;
      IMM_J:    w_imm_final = w_imm_J;
      default:  w_imm_final = 32'b0;
    endcase
  end

  // module instatiation
  riscv32_RDU #(
      .DATA_WIDTH(DATA_WIDTH)
  ) U_RDU (
      .i_ex_redirect_valid(w_ex_result.redirect_valid),
      .i_ex_redirect_pc(w_ex_result.redirect_pc),

      .i_trap_redirect_valid(w_decode_ctrl.ecall_en),
      .i_trap_vector_pc(w_csr_mtvec),

      .i_mret_redirect_valid(w_decode_ctrl.mret_en),
      .i_mret_pc(w_csr_mepc),

      .o_redirect_valid(w_redirect_valid),
      .o_redirect_pc(w_redirect_pc)
  );

  riscv32_IFU #(
      .DATA_WIDTH(DATA_WIDTH),
      .PC_START  (32'h80000000)
  ) U_IFU (
      .clk(clk),
      .rstn(rstn),
      // IFU consumes redirect, not a jump-specific signal. This same interface
      // can later carry branch recovery, exception, mret, or debug redirects.
      .i_if_redirect_valid(w_redirect_valid),
      .i_if_redirect_pc(w_redirect_pc),
      .o_if_pc(w_pc),
      .o_if_instruction(w_instruction)
  );

  riscv32_IDU #(
      .DATA_WIDTH(DATA_WIDTH)
  ) U_IDU (
      .i_id_instruction(w_instruction),

      .o_id_opcode(w_opcode),

      .o_id_rd_addr (w_rd_addr),
      .o_id_rs2_addr(w_rs2_addr),
      .o_id_rs1_addr(w_rs1_addr),

      .o_id_funct_3 (w_funct_3),
      .o_id_funct_7 (w_funct_7),
      .o_id_funct_12(w_funct_12),

      .o_id_imm_I(w_imm_I),
      .o_id_imm_S(w_imm_S),
      .o_id_imm_U(w_imm_U),
      .o_id_imm_B(w_imm_B),
      .o_id_imm_J(w_imm_J)
  );

  riscv32_Decoder U_DECODER (
      .i_dec_opcode(w_opcode),

      .i_dec_funct_3 (w_funct_3),
      .i_dec_funct_7 (w_funct_7),
      .i_dec_funct_12(w_funct_12),

      .i_dec_rd_addr (w_rd_addr),
      .i_dec_rs1_addr(w_rs1_addr),
      .i_dec_rs2_addr(w_rs2_addr),

      .o_dec_ctrl(w_decode_ctrl)
  );

  RegisterFile #(
      .DATA_WIDTH(DATA_WIDTH),
      .ADDR_WIDTH(ADDR_WIDTH)
  ) U_RF (
      .clk(clk),
      .i_RF_wdata(w_wbu_wdata),
      .i_RF_waddr(w_wbu_waddr),
      .i_RF_wen(w_wbu_wen),
      .i_RF_raddr1(w_rs1_addr),
      .o_RF_rdata1(w_rs1_data),
      .i_RF_raddr2(w_rs2_addr),
      .o_RF_rdata2(w_rs2_data)
  );

  riscv32_CSR #(
      .ADDR_WIDTH(12),
      .DATA_WIDTH(DATA_WIDTH)
  ) U_CSR (
      .clk(clk),
      .rst(~rstn),

      .i_csr_ren (w_decode_ctrl.csr_ren),
      .i_csr_wren(w_decode_ctrl.csr_wren),
      .i_csr_addr(w_funct_12),
      .i_csr_op  (w_decode_ctrl.csr_op),
      .i_csr_src (w_rs1_data),

      .i_trap_valid (w_decode_ctrl.ecall_en),
      .i_trap_mepc  (w_pc),
      .i_trap_mcause(32'd11),

      .o_csr_mtvec(w_csr_mtvec),
      .o_csr_mepc (w_csr_mepc),

      .o_csr_rdata  (w_csr_rdata),
      .o_csr_illegal(w_csr_illegal)
  );

  riscv32_EXU #(
      .DATA_WIDTH(DATA_WIDTH),
      .ADDR_WIDTH(ADDR_WIDTH)
  ) U_EXU (
      .i_ex_pc(w_pc),
      .i_ex_rs1_data(w_rs1_data),
      .i_ex_rs2_data(w_rs2_data),
      .i_ex_rd_addr(w_rd_addr),
      .i_ex_imm(w_imm_final),
      .i_ex_alu_src1_sel(w_decode_ctrl.alu_src1_sel),
      .i_ex_alu_src2_sel(w_decode_ctrl.alu_src2_sel),
      .i_ex_alu_op(w_decode_ctrl.alu_op),
      .i_ex_branch_op(w_decode_ctrl.branch_op),
      .i_ex_branch_en(w_decode_ctrl.branch_en),
      .i_ex_jal_en(w_decode_ctrl.jal_en),
      .i_ex_jalr_en(w_decode_ctrl.jalr_en),

      // EXU completion is a single result record. Future EX/MEM register,
      // bypass network, and ROB completion port should preserve this boundary.
      .o_ex_result(w_ex_result),

      .i_ex_mem_cmd(w_decode_ctrl.mem_cmd),
      .i_ex_mem_size(w_decode_ctrl.mem_size),
      .i_ex_mem_unsigned(w_decode_ctrl.mem_unsigned),
      .i_ex_reg_wen(w_decode_ctrl.reg_wen),
      .i_ex_wb_sel(w_decode_ctrl.wb_sel)
  );

  riscv32_LSU #(
      .DATA_WIDTH(DATA_WIDTH)
  ) U_LSU (
      // LSU consumes the whole EXU result record: address, store data, memory
      // command, size, sign mode, and writeback metadata stay together.
      .i_lsu_ex_result(w_ex_result),
      .o_lsu_result(w_lsu_result)
  );

  riscv32_WBU #(
      .DATA_WIDTH(DATA_WIDTH),
      .ADDR_WIDTH(ADDR_WIDTH)
  ) U_WBU (
      // WBU consumes the LSU completion record. Writeback arbitration and
      // bypass sources should use structured result records, not top-level
      // reconstructed wires.
      .i_wbu_lsu_result(w_lsu_result),
      .i_wbu_csr_rdata (w_csr_rdata),

      .o_wbu_wdata(w_wbu_wdata),
      .o_wbu_waddr(w_wbu_waddr),
      .o_wbu_wen  (w_wbu_wen)
  );

  import "DPI-C" context function void npc_set_dpi_scope();
  initial begin
    npc_set_dpi_scope();
  end

  // expose PC and instruction
  export "DPI-C" function npc_get_pc_dpi;
  export "DPI-C" function npc_get_inst_dpi;

  function int npc_get_pc_dpi();
    npc_get_pc_dpi = w_pc;
  endfunction

  function int npc_get_inst_dpi();
    npc_get_inst_dpi = w_instruction;
  endfunction

  import "DPI-C" context function void ebreak_halt();

  always_ff @(posedge clk) begin
    // Current C2 halts directly in top. In a pipelined or OoO CPU, ebreak/trap
    // should be carried to commit/retire instead of stopping at decode.
    if (rstn && w_decode_ctrl.ebreak_en) begin
      ebreak_halt();
    end
  end

endmodule
