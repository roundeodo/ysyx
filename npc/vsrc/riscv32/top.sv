module top
  import riscv32_pkg::*;
(
    input logic clk,
    input logic rstn
);
  localparam int unsigned REDIRECT_SOURCE_COUNT = 2;
  localparam int unsigned EXECUTE_REDIRECT = 0;
  localparam int unsigned COMMIT_REDIRECT = 1;

  fetch_entry_t                                  fetch_entry;
  logic                                          fetch_valid;
  logic                                          fetch_ready;

  decoded_uop_t                                  decoded_uop;
  logic                                          decoded_valid;
  logic                                          decoded_ready;

  logic              [                 XLEN-1:0] rs1_value;
  logic              [                 XLEN-1:0] rs2_value;
  execute_packet_t                               execute_packet;
  logic                                          execute_ready;

  execute_result_t                               direct_result;
  logic                                          direct_valid;
  logic                                          direct_ready;

  execute_result_t                               memory_execute_result;
  logic                                          memory_execute_valid;
  logic                                          memory_execute_ready;

  writeback_result_t                             memory_writeback_result;
  logic                                          memory_writeback_valid;
  logic                                          memory_writeback_ready;

  writeback_result_t                             writeback_result;
  logic                                          writeback_valid;
  logic                                          writeback_ready;

  commit_t                                       commit;
  logic                                          commit_valid;
  logic              [                 XLEN-1:0] rf_write_data;
  arch_reg_idx_t                                 rf_write_addr;
  logic                                          rf_write_enable;

  logic              [                 XLEN-1:0] csr_read_data;
  logic                                          csr_read_illegal;
  logic              [                 XLEN-1:0] csr_mtvec;
  logic              [                 XLEN-1:0] csr_mepc;

  logic                                          trap_valid;
  logic              [                 XLEN-1:0] trap_pc;
  logic              [                 XLEN-1:0] trap_cause;
  logic              [                 XLEN-1:0] trap_tval;
  logic                                          mret_valid;

  redirect_req_t                                 redirect_request        [REDIRECT_SOURCE_COUNT];
  logic              [REDIRECT_SOURCE_COUNT-1:0] redirect_request_valid;
  redirect_req_t                                 selected_redirect;
  logic                                          selected_redirect_valid;

  always_comb begin
    execute_packet             = '0;
    execute_packet.uop         = decoded_uop;
    execute_packet.rs1_value   = rs1_value;
    execute_packet.rs2_value   = rs2_value;
    execute_packet.csr_rdata   = csr_read_data;
    execute_packet.csr_illegal = csr_read_illegal;
  end

  riscv32_ifu u_ifu (
      .clk_i           (clk),
      .rst_ni          (rstn),
      .redirect_i      (selected_redirect),
      .redirect_valid_i(selected_redirect_valid),
      .fetch_entry_o   (fetch_entry),
      .fetch_valid_o   (fetch_valid),
      .fetch_ready_i   (fetch_ready)
  );

  riscv32_idu u_idu (
      .fetch_entry_i  (fetch_entry),
      .fetch_valid_i  (fetch_valid),
      .fetch_ready_o  (fetch_ready),
      .decoded_uop_o  (decoded_uop),
      .decoded_valid_o(decoded_valid),
      .decoded_ready_i(decoded_ready)
  );

  riscv32_arch_regfile u_arch_regfile (
      .clk_i         (clk),
      .write_data_i  (rf_write_data),
      .write_addr_i  (rf_write_addr),
      .write_enable_i(rf_write_enable),
      .read_addr_a_i (decoded_uop.rs1),
      .read_data_a_o (rs1_value),
      .read_addr_b_i (decoded_uop.rs2),
      .read_data_b_o (rs2_value)
  );

  riscv32_csr_file u_csr_file (
      .clk_i             (clk),
      .rst_ni            (rstn),
      .csr_read_enable_i (decoded_valid && decoded_uop.csr_ctrl.read_enable),
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
      .execute_packet_i(execute_packet),
      .execute_valid_i (decoded_valid),
      .execute_ready_o (execute_ready),
      .direct_result_o (direct_result),
      .direct_valid_o  (direct_valid),
      .direct_ready_i  (direct_ready),
      .memory_result_o (memory_execute_result),
      .memory_valid_o  (memory_execute_valid),
      .memory_ready_i  (memory_execute_ready)
  );

  assign decoded_ready = execute_ready;

  riscv32_lsu u_lsu (
      .clk_i             (clk),
      .memory_result_i   (memory_execute_result),
      .memory_valid_i    (memory_execute_valid),
      .memory_ready_o    (memory_execute_ready),
      .writeback_result_o(memory_writeback_result),
      .writeback_valid_o (memory_writeback_valid),
      .writeback_ready_i (memory_writeback_ready)
  );

  riscv32_completion_mux u_completion_mux (
      .direct_result_i  (direct_result),
      .direct_valid_i   (direct_valid),
      .direct_ready_o   (direct_ready),
      .memory_result_i  (memory_writeback_result),
      .memory_valid_i   (memory_writeback_valid),
      .memory_ready_o   (memory_writeback_ready),
      .writeback_result_o(writeback_result),
      .writeback_valid_o (writeback_valid),
      .writeback_ready_i (writeback_ready)
  );

  riscv32_commit u_commit (
      .writeback_result_i(writeback_result),
      .writeback_valid_i (writeback_valid),
      .writeback_ready_o (writeback_ready),
      .commit_o          (commit),
      .commit_valid_o    (commit_valid),
      .rf_wdata_o        (rf_write_data),
      .rf_waddr_o        (rf_write_addr),
      .rf_wen_o          (rf_write_enable)
  );

  riscv32_trap_controller u_trap_controller (
      .commit_i        (commit),
      .commit_valid_i  (commit_valid),
      .mtvec_i         (csr_mtvec),
      .mepc_i          (csr_mepc),
      .trap_valid_o    (trap_valid),
      .trap_pc_o       (trap_pc),
      .trap_cause_o    (trap_cause),
      .trap_tval_o     (trap_tval),
      .mret_valid_o    (mret_valid),
      .redirect_o      (redirect_request[COMMIT_REDIRECT]),
      .redirect_valid_o(redirect_request_valid[COMMIT_REDIRECT])
  );

  assign redirect_request[EXECUTE_REDIRECT] = direct_result.redirect;
  assign redirect_request_valid[EXECUTE_REDIRECT] = direct_valid && direct_ready &&
                                                     direct_result.redirect_valid;

  riscv32_redirect_arbiter #(
      .SOURCE_COUNT(REDIRECT_SOURCE_COUNT)
  ) u_redirect_arbiter (
      .redirect_i      (redirect_request),
      .redirect_valid_i(redirect_request_valid),
      .redirect_o      (selected_redirect),
      .redirect_valid_o(selected_redirect_valid)
  );

  // P0 simulation boundary. NOTE(P1): move these DPI hooks into
  // riscv32_sim_debug after riscv32_core is split from this top module.
  import "DPI-C" context function void npc_set_dpi_scope();
  import "DPI-C" context function void ebreak_halt();

  initial begin
    npc_set_dpi_scope();
  end

  export "DPI-C" function npc_get_pc_dpi;
  export "DPI-C" function npc_get_inst_dpi;

  function int npc_get_pc_dpi();
    npc_get_pc_dpi = fetch_entry.pc;
  endfunction

  function int npc_get_inst_dpi();
    npc_get_inst_dpi = fetch_entry.instruction;
  endfunction

  always_ff @(posedge clk) begin
    if (rstn && commit_valid && (commit.system_op == SYS_EBREAK)) begin
      ebreak_halt();
    end
  end

endmodule
