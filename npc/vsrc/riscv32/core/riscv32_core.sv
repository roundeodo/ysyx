// Synthesizable processor core. Simulation memory, DPI, and shared-system
// arbitration are intentionally outside this module.
module riscv32_core
  import riscv32_pkg::*;
(
    input logic clk_i,
    input logic rst_ni,

    // Instruction read master port
    output axi_lite_addr_t ifu_axi_ar_o,
    output logic           ifu_axi_arvalid_o,
    input  logic           ifu_axi_arready_i,
    input  axi_lite_r_t    ifu_axi_r_i,
    input  logic           ifu_axi_rvalid_i,
    output logic           ifu_axi_rready_o,

    // Data read/write master port
    output axi_lite_addr_t lsu_axi_ar_o,
    output logic           lsu_axi_arvalid_o,
    input  logic           lsu_axi_arready_i,
    input  axi_lite_r_t    lsu_axi_r_i,
    input  logic           lsu_axi_rvalid_i,
    output logic           lsu_axi_rready_o,

    output axi_lite_addr_t lsu_axi_aw_o,
    output logic           lsu_axi_awvalid_o,
    input  logic           lsu_axi_awready_i,
    output axi_lite_w_t    lsu_axi_w_o,
    output logic           lsu_axi_wvalid_o,
    input  logic           lsu_axi_wready_i,
    input  axi_lite_b_t    lsu_axi_b_i,
    input  logic           lsu_axi_bvalid_i,
    output logic           lsu_axi_bready_o
);
  localparam int unsigned REDIRECT_SOURCE_COUNT = 2;
  localparam int unsigned EXU_REDIRECT_INDEX = 0;
  localparam int unsigned COMMIT_REDIRECT_INDEX = 1;

  fetch_entry_t fetch_entry;
  logic fetch_entry_valid;
  logic fetch_entry_ready;

  decoded_uop_t decoded_uop;
  logic decoded_uop_valid;
  logic decoded_uop_ready;

  logic [XLEN-1:0] rs1_value;
  logic [XLEN-1:0] rs2_value;
  execute_packet_t execute_packet;
  logic execute_packet_ready;

  execute_result_t exu_result;
  logic exu_result_valid;
  logic exu_result_ready;

  lsu_req_t lsu_req;
  logic lsu_req_valid;
  logic lsu_req_ready;

  writeback_result_t lsu_writeback;
  logic lsu_writeback_valid;
  logic lsu_writeback_ready;

  writeback_result_t writeback_result;
  logic writeback_result_valid;
  logic writeback_result_ready;

  commit_t commit;
  logic commit_valid;
  logic [XLEN-1:0] gpr_write_data;
  arch_reg_idx_t gpr_write_addr;
  logic gpr_write_enable;

  logic [XLEN-1:0] csr_read_data;
  logic csr_read_illegal;
  logic [XLEN-1:0] csr_mtvec;
  logic [XLEN-1:0] csr_mepc;

  logic trap_valid;
  logic [XLEN-1:0] trap_pc;
  logic [XLEN-1:0] trap_cause;
  logic [XLEN-1:0] trap_tval;
  logic mret_valid;

  redirect_req_t redirect_req[REDIRECT_SOURCE_COUNT];
  logic [REDIRECT_SOURCE_COUNT-1:0] redirect_req_valid;
  redirect_req_t selected_redirect_req;
  logic selected_redirect_req_valid;

  always_comb begin
    execute_packet             = '0;
    execute_packet.uop         = decoded_uop;
    execute_packet.rs1_value   = rs1_value;
    execute_packet.rs2_value   = rs2_value;
    execute_packet.csr_rdata   = csr_read_data;
    execute_packet.csr_illegal = csr_read_illegal;
  end

  riscv32_ifu u_ifu (
      .clk_i               (clk_i),
      .rst_ni              (rst_ni),
      .redirect_req_i      (selected_redirect_req),
      .redirect_req_valid_i(selected_redirect_req_valid),
      .ifu_axi_ar_o        (ifu_axi_ar_o),
      .ifu_axi_arvalid_o   (ifu_axi_arvalid_o),
      .ifu_axi_arready_i   (ifu_axi_arready_i),
      .ifu_axi_r_i         (ifu_axi_r_i),
      .ifu_axi_rvalid_i    (ifu_axi_rvalid_i),
      .ifu_axi_rready_o    (ifu_axi_rready_o),
      .fetch_entry_o       (fetch_entry),
      .fetch_entry_valid_o (fetch_entry_valid),
      .fetch_entry_ready_i (fetch_entry_ready)
  );

  riscv32_idu u_idu (
      .fetch_entry_i      (fetch_entry),
      .fetch_entry_valid_i(fetch_entry_valid),
      .fetch_entry_ready_o(fetch_entry_ready),
      .decoded_uop_o      (decoded_uop),
      .decoded_uop_valid_o(decoded_uop_valid),
      .decoded_uop_ready_i(decoded_uop_ready)
  );

  riscv32_arch_regfile u_arch_regfile (
      .clk_i             (clk_i),
      .gpr_write_data_i  (gpr_write_data),
      .gpr_write_addr_i  (gpr_write_addr),
      .gpr_write_enable_i(gpr_write_enable),
      .rs1_addr_i        (decoded_uop.rs1),
      .rs1_data_o        (rs1_value),
      .rs2_addr_i        (decoded_uop.rs2),
      .rs2_data_o        (rs2_value)
  );

  riscv32_csr_file u_csr_file (
      .clk_i             (clk_i),
      .rst_ni            (rst_ni),
      .csr_read_enable_i (decoded_uop_valid && decoded_uop.csr_ctrl.read_enable),
      .csr_read_addr_i   (decoded_uop.csr_ctrl.addr),
      .csr_read_data_o   (csr_read_data),
      .csr_read_illegal_o(csr_read_illegal),
      .csr_write_valid_i (commit_valid && commit.csr_write),
      .csr_write_addr_i  (commit.csr_addr),
      .csr_write_data_i  (commit.csr_wdata),
      .trap_valid_i      (trap_valid),
      .trap_pc_i         (trap_pc),
      .trap_cause_i      (trap_cause),
      .trap_tval_i       (trap_tval),
      .mret_valid_i      (mret_valid),
      .mtvec_o           (csr_mtvec),
      .mepc_o            (csr_mepc)
  );

  riscv32_exu u_exu (
      .execute_packet_i      (execute_packet),
      .execute_packet_valid_i(decoded_uop_valid && lsu_req_ready),
      .execute_packet_ready_o(execute_packet_ready),
      .exu_result_o          (exu_result),
      .exu_result_valid_o    (exu_result_valid),
      .exu_result_ready_i    (exu_result_ready),
      .lsu_req_o             (lsu_req),
      .lsu_req_valid_o       (lsu_req_valid),
      .lsu_req_ready_i       (lsu_req_ready)
  );

  // This checkpoint retires in order and has no ROB. Hold younger decode work
  // while the LSU owns the single in-flight instruction slot.
  assign decoded_uop_ready = execute_packet_ready && lsu_req_ready;

  riscv32_lsu u_lsu (
      .clk_i                (clk_i),
      .rst_ni               (rst_ni),
      .lsu_req_i            (lsu_req),
      .lsu_req_valid_i      (lsu_req_valid),
      .lsu_req_ready_o      (lsu_req_ready),
      .lsu_writeback_o      (lsu_writeback),
      .lsu_writeback_valid_o(lsu_writeback_valid),
      .lsu_writeback_ready_i(lsu_writeback_ready),
      .lsu_axi_ar_o         (lsu_axi_ar_o),
      .lsu_axi_arvalid_o    (lsu_axi_arvalid_o),
      .lsu_axi_arready_i    (lsu_axi_arready_i),
      .lsu_axi_r_i          (lsu_axi_r_i),
      .lsu_axi_rvalid_i     (lsu_axi_rvalid_i),
      .lsu_axi_rready_o     (lsu_axi_rready_o),
      .lsu_axi_aw_o         (lsu_axi_aw_o),
      .lsu_axi_awvalid_o    (lsu_axi_awvalid_o),
      .lsu_axi_awready_i    (lsu_axi_awready_i),
      .lsu_axi_w_o          (lsu_axi_w_o),
      .lsu_axi_wvalid_o     (lsu_axi_wvalid_o),
      .lsu_axi_wready_i     (lsu_axi_wready_i),
      .lsu_axi_b_i          (lsu_axi_b_i),
      .lsu_axi_bvalid_i     (lsu_axi_bvalid_i),
      .lsu_axi_bready_o     (lsu_axi_bready_o)
  );

  riscv32_completion_mux u_completion_mux (
      .exu_result_i            (exu_result),
      .exu_result_valid_i      (exu_result_valid),
      .exu_result_ready_o      (exu_result_ready),
      .lsu_writeback_i         (lsu_writeback),
      .lsu_writeback_valid_i   (lsu_writeback_valid),
      .lsu_writeback_ready_o   (lsu_writeback_ready),
      .writeback_result_o      (writeback_result),
      .writeback_result_valid_o(writeback_result_valid),
      .writeback_result_ready_i(writeback_result_ready)
  );

  riscv32_commit u_commit (
      .writeback_result_i      (writeback_result),
      .writeback_result_valid_i(writeback_result_valid),
      .writeback_result_ready_o(writeback_result_ready),
      .commit_o                (commit),
      .commit_valid_o          (commit_valid),
      .gpr_write_data_o        (gpr_write_data),
      .gpr_write_addr_o        (gpr_write_addr),
      .gpr_write_enable_o      (gpr_write_enable)
  );

  riscv32_trap_controller u_trap_controller (
      .commit_i            (commit),
      .commit_valid_i      (commit_valid),
      .mtvec_i             (csr_mtvec),
      .mepc_i              (csr_mepc),
      .trap_valid_o        (trap_valid),
      .trap_pc_o           (trap_pc),
      .trap_cause_o        (trap_cause),
      .trap_tval_o         (trap_tval),
      .mret_valid_o        (mret_valid),
      .redirect_req_o      (redirect_req[COMMIT_REDIRECT_INDEX]),
      .redirect_req_valid_o(redirect_req_valid[COMMIT_REDIRECT_INDEX])
  );

  assign redirect_req[EXU_REDIRECT_INDEX] = exu_result.redirect_req;
  assign redirect_req_valid[EXU_REDIRECT_INDEX] = exu_result_valid && exu_result_ready &&
                                                   exu_result.redirect_valid;

  riscv32_redirect_arbiter #(
      .SOURCE_COUNT(REDIRECT_SOURCE_COUNT)
  ) u_redirect_arbiter (
      .redirect_req_i               (redirect_req),
      .redirect_req_valid_i         (redirect_req_valid),
      .selected_redirect_req_o      (selected_redirect_req),
      .selected_redirect_req_valid_o(selected_redirect_req_valid)
  );

endmodule
