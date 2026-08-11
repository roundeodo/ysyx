// Synthesizable processor core. Simulation memory, DPI, and shared-system
// arbitration are intentionally outside this module.
module riscv32_core
  import riscv32_pkg::*;
  import riscv32_axi4_pkg::*;
#(
    parameter logic [XLEN-1:0] RESET_PC = RESET_VECTOR
) (
    input logic clk_i,
    input logic rst_ni,

    // 取指和数据访问保持为两个独立manager。系统层负责仲裁和地址路由，
    // core内部不感知SoC拓扑。
    output axi4_manager_to_target_t instruction_axi4_manager_o,
    input  axi4_target_to_manager_t instruction_axi4_manager_i,

    output axi4_manager_to_target_t data_axi4_manager_o,
    input  axi4_target_to_manager_t data_axi4_manager_i
);
  localparam int unsigned REDIRECT_SOURCE_COUNT = 2;
  localparam int unsigned EXU_REDIRECT_INDEX = 0;
  localparam int unsigned COMMIT_REDIRECT_INDEX = 1;

  icache_lookup_req_t  icache_lookup_req;
  logic                icache_lookup_req_valid;
  logic                icache_lookup_req_ready;
  icache_lookup_resp_t icache_lookup_resp;
  logic                icache_lookup_resp_valid;
  logic                icache_lookup_resp_ready;

  icache_refill_req_t  icache_refill_req;
  logic                icache_refill_req_valid;
  logic                icache_refill_req_ready;
  icache_refill_resp_t icache_refill_resp;
  logic                icache_refill_resp_valid;
  logic                icache_refill_resp_ready;

  data_memory_req_t  data_memory_req;
  logic              data_memory_req_valid;
  logic              data_memory_req_ready;
  data_memory_resp_t data_memory_resp;
  logic              data_memory_resp_valid;
  logic              data_memory_resp_ready;

  icache_event_t icache_event;
  logic          icache_invalidate_req;
  logic          icache_invalidate_done;
  logic          icache_busy;

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
  logic retired_instruction_occurred;

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

  riscv32_ifu #(
      .PC_START(RESET_PC)
  ) u_ifu (
      .clk_i               (clk_i),
      .rst_ni              (rst_ni),
      .redirect_req_i      (selected_redirect_req),
      .redirect_req_valid_i(selected_redirect_req_valid),
      .icache_lookup_req_o (icache_lookup_req),
      .icache_lookup_req_valid_o(icache_lookup_req_valid),
      .icache_lookup_req_ready_i(icache_lookup_req_ready),
      .icache_lookup_resp_i(icache_lookup_resp),
      .icache_lookup_resp_valid_i(icache_lookup_resp_valid),
      .icache_lookup_resp_ready_o(icache_lookup_resp_ready),
      .fetch_entry_o       (fetch_entry),
      .fetch_entry_valid_o (fetch_entry_valid),
      .fetch_entry_ready_i (fetch_entry_ready)
  );

  riscv32_icache u_icache (
      .clk_i                  (clk_i),
      .rst_ni                 (rst_ni),
      .lookup_req_i           (icache_lookup_req),
      .lookup_req_valid_i     (icache_lookup_req_valid),
      .lookup_req_ready_o     (icache_lookup_req_ready),
      .lookup_resp_o          (icache_lookup_resp),
      .lookup_resp_valid_o    (icache_lookup_resp_valid),
      .lookup_resp_ready_i    (icache_lookup_resp_ready),
      .invalidate_req_i       (icache_invalidate_req),
      .invalidate_done_o      (icache_invalidate_done),
      .cache_busy_o           (icache_busy),
      .refill_req_o           (icache_refill_req),
      .refill_req_valid_o     (icache_refill_req_valid),
      .refill_req_ready_i     (icache_refill_req_ready),
      .refill_resp_i          (icache_refill_resp),
      .refill_resp_valid_i    (icache_refill_resp_valid),
      .refill_resp_ready_o    (icache_refill_resp_ready),
      .event_o                (icache_event)
  );

  riscv32_icache_refill_axi4_master u_icache_refill_axi4_master (
      .clk_i               (clk_i),
      .rst_ni              (rst_ni),
      .refill_req_i        (icache_refill_req),
      .refill_req_valid_i  (icache_refill_req_valid),
      .refill_req_ready_o  (icache_refill_req_ready),
      .refill_resp_o       (icache_refill_resp),
      .refill_resp_valid_o (icache_refill_resp_valid),
      .refill_resp_ready_i (icache_refill_resp_ready),
      .axi_manager_o       (instruction_axi4_manager_o),
      .axi_manager_i       (instruction_axi4_manager_i)
  );

  // TODO(ICACHE-CORE-FENCE-I): 在本TODO正下方用“已提交的fence.i事件”驱动
  // `icache_invalidate_req`。不要在decode阶段失效缓存；乱序实现中，只有commit阶段
  // 才能保证该指令不会因异常或分支误预测被取消。接入前需要先在decoded_uop_t和
  // commit_t中增加明确的fence_i字段，并让commit在该指令到达提交点时产生一次脉冲。

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
      .clk_i                         (clk_i),
      .rst_ni                        (rst_ni),
      .csr_read_enable_i             (decoded_uop_valid && decoded_uop.csr_ctrl.read_enable),
      .csr_read_addr_i               (decoded_uop.csr_ctrl.addr),
      .csr_read_data_o               (csr_read_data),
      .csr_read_illegal_o            (csr_read_illegal),
      .csr_write_valid_i             (commit_valid && commit.csr_write),
      .csr_write_addr_i              (commit.csr_addr),
      .csr_write_data_i              (commit.csr_wdata),
      .retired_instruction_occurred_i(retired_instruction_occurred),
      .trap_valid_i                  (trap_valid),
      .trap_pc_i                     (trap_pc),
      .trap_cause_i                  (trap_cause),
      .trap_tval_i                   (trap_tval),
      .mret_valid_i                  (mret_valid),
      .mtvec_o                       (csr_mtvec),
      .mepc_o                        (csr_mepc)
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
      .data_memory_req_o    (data_memory_req),
      .data_memory_req_valid_o(data_memory_req_valid),
      .data_memory_req_ready_i(data_memory_req_ready),
      .data_memory_resp_i   (data_memory_resp),
      .data_memory_resp_valid_i(data_memory_resp_valid),
      .data_memory_resp_ready_o(data_memory_resp_ready)
  );

  riscv32_uncached_axi4_master u_uncached_axi4_master (
      .clk_i                    (clk_i),
      .rst_ni                   (rst_ni),
      .data_memory_req_i        (data_memory_req),
      .data_memory_req_valid_i  (data_memory_req_valid),
      .data_memory_req_ready_o  (data_memory_req_ready),
      .data_memory_resp_o       (data_memory_resp),
      .data_memory_resp_valid_o (data_memory_resp_valid),
      .data_memory_resp_ready_i (data_memory_resp_ready),
      .axi_manager_o            (data_axi4_manager_o),
      .axi_manager_i            (data_axi4_manager_i)
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

  // A synchronous exception reaches the commit boundary but does not retire the
  // faulting instruction. Future multi-commit logic will replace this scalar
  // event with the number of non-trapping instructions retired in this cycle.
  assign retired_instruction_occurred = commit_valid && !commit.trap_taken;

`ifdef NPC_ENABLE_SIM_MONITOR
  // 这里的IFU事件使用lookup层语义；下层AXI4只统计真正发生的refill事务。
  riscv32_sim_performance_monitor u_sim_performance_monitor (
      .clk_i(clk_i),
      .rst_ni(rst_ni),
      .ifu_instruction_request_occurred_i(icache_lookup_req_valid && icache_lookup_req_ready),
      .ifu_instruction_request_waiting_i(icache_lookup_req_valid && !icache_lookup_req_ready),
      .ifu_instruction_response_occurred_i(icache_lookup_resp_valid && icache_lookup_resp_ready),
      .ifu_instruction_response_discarded_occurred_i(
          icache_lookup_resp_valid && icache_lookup_resp_ready && !fetch_entry_valid
      ),
      .ifu_instruction_delivery_occurred_i(fetch_entry_valid && fetch_entry_ready),
      .ifu_downstream_waiting_i(fetch_entry_valid && !fetch_entry_ready),
      .instruction_decode_occurred_i(decoded_uop_valid && decoded_uop_ready),
      .decoded_fu_type_i(decoded_uop.fu_type),
      .decoded_memory_cmd_i(decoded_uop.mem_ctrl.cmd),
      .exu_completion_occurred_i(exu_result_valid && exu_result_ready),
      .lsu_completion_occurred_i(lsu_writeback_valid && lsu_writeback_ready),
      .instruction_retirement_occurred_i(retired_instruction_occurred),
      .lsu_request_occurred_i(lsu_req_valid && lsu_req_ready),
      .lsu_request_memory_cmd_i(lsu_req.uop.mem_ctrl.cmd),
      .lsu_read_address_occurred_i(data_axi4_manager_o.ar_valid &&
                                   data_axi4_manager_i.ar_ready),
      .lsu_read_response_occurred_i(data_axi4_manager_i.r_valid &&
                                    data_axi4_manager_o.r_ready),
      .lsu_write_address_occurred_i(data_axi4_manager_o.aw_valid &&
                                    data_axi4_manager_i.aw_ready),
      .lsu_write_data_occurred_i(data_axi4_manager_o.w_valid &&
                                 data_axi4_manager_i.w_ready),
      .lsu_write_response_occurred_i(data_axi4_manager_i.b_valid &&
                                     data_axi4_manager_o.b_ready)
  );
`endif

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
