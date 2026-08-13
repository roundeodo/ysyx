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
  localparam int unsigned REDIRECT_SOURCE_COUNT = 3;
  localparam int unsigned EXU_REDIRECT_INDEX = 0;
  localparam int unsigned FENCE_I_REDIRECT_INDEX = 1;
  localparam int unsigned COMMIT_REDIRECT_INDEX = 2;

  icache_lookup_req_t icache_lookup_req;
  logic icache_lookup_req_valid;
  logic icache_lookup_req_ready;
  icache_lookup_resp_t icache_lookup_resp;
  logic icache_lookup_resp_valid;
  logic icache_lookup_resp_ready;

  icache_refill_req_t icache_refill_req;
  logic icache_refill_req_valid;
  logic icache_refill_req_ready;
  icache_refill_resp_t icache_refill_resp;
  logic icache_refill_resp_valid;
  logic icache_refill_resp_ready;

  data_memory_req_t data_memory_req;
  logic data_memory_req_valid;
  logic data_memory_req_ready;
  data_memory_resp_t data_memory_resp;
  logic data_memory_resp_valid;
  logic data_memory_resp_ready;

  icache_event_t icache_event;
  logic icache_invalidate_req;
  logic icache_invalidate_done;
  logic icache_busy;

  // IFU侧表示“等待入队”，IDU侧表示“队首等待消费”。
  // 两个边界各自使用ready/valid，避免把buffer的入队和出队握手混在一起。
  fetch_entry_t ifu_fetch_entry;
  logic ifu_fetch_entry_valid;
  logic ifu_fetch_entry_ready;

  fetch_entry_t idu_fetch_entry;
  logic idu_fetch_entry_valid;
  logic idu_fetch_entry_ready;

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
  logic committed_fence_i_occurred;
  redirect_req_t fence_i_redirect_req;

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
      .clk_i                     (clk_i),
      .rst_ni                    (rst_ni),
      .redirect_req_i            (selected_redirect_req),
      .redirect_req_valid_i      (selected_redirect_req_valid),
      .icache_lookup_req_o       (icache_lookup_req),
      .icache_lookup_req_valid_o (icache_lookup_req_valid),
      .icache_lookup_req_ready_i (icache_lookup_req_ready),
      .icache_lookup_resp_i      (icache_lookup_resp),
      .icache_lookup_resp_valid_i(icache_lookup_resp_valid),
      .icache_lookup_resp_ready_o(icache_lookup_resp_ready),
      // IFU只与fetch buffer的入队端交互，不直接感知IDU反压。
      .fetch_entry_o             (ifu_fetch_entry),
      .fetch_entry_valid_o       (ifu_fetch_entry_valid),
      .fetch_entry_ready_i       (ifu_fetch_entry_ready)
  );

  riscv32_icache u_icache (
      .clk_i              (clk_i),
      .rst_ni             (rst_ni),
      .lookup_req_i       (icache_lookup_req),
      .lookup_req_valid_i (icache_lookup_req_valid),
      .lookup_req_ready_o (icache_lookup_req_ready),
      .lookup_resp_o      (icache_lookup_resp),
      .lookup_resp_valid_o(icache_lookup_resp_valid),
      .lookup_resp_ready_i(icache_lookup_resp_ready),
      .invalidate_req_i   (icache_invalidate_req),
      .invalidate_done_o  (icache_invalidate_done),
      .cache_busy_o       (icache_busy),
      .refill_req_o       (icache_refill_req),
      .refill_req_valid_o (icache_refill_req_valid),
      .refill_req_ready_i (icache_refill_req_ready),
      .refill_resp_i      (icache_refill_resp),
      .refill_resp_valid_i(icache_refill_resp_valid),
      .refill_resp_ready_o(icache_refill_resp_ready),
      .event_o            (icache_event)
  );

  riscv32_icache_refill_axi4_master u_icache_refill_axi4_master (
      .clk_i              (clk_i),
      .rst_ni             (rst_ni),
      .refill_req_i       (icache_refill_req),
      .refill_req_valid_i (icache_refill_req_valid),
      .refill_req_ready_o (icache_refill_req_ready),
      .refill_resp_o      (icache_refill_resp),
      .refill_resp_valid_o(icache_refill_resp_valid),
      .refill_resp_ready_i(icache_refill_resp_ready),
      .axi_manager_o      (instruction_axi4_manager_o),
      .axi_manager_i      (instruction_axi4_manager_i)
  );

  // fence.i只能在提交边界使I-cache失效，避免未提交指令修改前端状态。
  // 当前顺序核可在同一拍发出redirect和invalidate；I-cache busy会反压新取指，
  // 直到失效扫描结束。未来乱序核仍应由commit/ROB生成这个事件。
  assign committed_fence_i_occurred = commit_valid && !commit.trap_taken && (commit.system_op == SYS_FENCE_I);
  assign icache_invalidate_req = committed_fence_i_occurred;

  // buffer位于IFU和IDU之间，只保存已经完成的fetch_entry，不参与PC生成、cache访问或译码。
  // redirect必须在发生的同一拍flush队列，因为队列中的entry属于旧控制流；当前标量顺序核没有
  // redirect ready，因此`selected_redirect_req_valid`本身就是重定向发生事件。flush时buffer会同时
  // 拉低上下游握手，防止旧entry在重定向当拍被IDU接收。
  riscv32_fetch_buffer #(
      .ENTRY_COUNT(2)
  ) u_fetch_buffer (
      .clk_i                  (clk_i),
      .rst_ni                 (rst_ni),
      .ifu_fetch_entry_i      (ifu_fetch_entry),
      .ifu_fetch_entry_valid_i(ifu_fetch_entry_valid),
      .ifu_fetch_entry_ready_o(ifu_fetch_entry_ready),
      .idu_fetch_entry_o      (idu_fetch_entry),
      .idu_fetch_entry_valid_o(idu_fetch_entry_valid),
      .idu_fetch_entry_ready_i(idu_fetch_entry_ready),
      .flush_i                (selected_redirect_req_valid)
  );
  // ENTRY_COUNT=2只表示当前前端最多缓冲两个已取回entry。未来改为多发射时，应把entry升级为
  // fetch packet，并根据取指宽度、译码宽度和分支恢复延迟重新确定深度，而不是继续堆标量队列。

  riscv32_idu u_idu (
      // IDU反压只能阻止buffer出队；只要buffer还有空位，IFU仍可继续交付已经完成的取指结果。
      .fetch_entry_i      (idu_fetch_entry),
      .fetch_entry_valid_i(idu_fetch_entry_valid),
      .fetch_entry_ready_o(idu_fetch_entry_ready),
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
      .icache_event_i                (icache_event),
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
      .clk_i                   (clk_i),
      .rst_ni                  (rst_ni),
      .lsu_req_i               (lsu_req),
      .lsu_req_valid_i         (lsu_req_valid),
      .lsu_req_ready_o         (lsu_req_ready),
      .lsu_writeback_o         (lsu_writeback),
      .lsu_writeback_valid_o   (lsu_writeback_valid),
      .lsu_writeback_ready_i   (lsu_writeback_ready),
      .data_memory_req_o       (data_memory_req),
      .data_memory_req_valid_o (data_memory_req_valid),
      .data_memory_req_ready_i (data_memory_req_ready),
      .data_memory_resp_i      (data_memory_resp),
      .data_memory_resp_valid_i(data_memory_resp_valid),
      .data_memory_resp_ready_o(data_memory_resp_ready)
  );

  riscv32_uncached_axi4_master u_uncached_axi4_master (
      .clk_i                   (clk_i),
      .rst_ni                  (rst_ni),
      .data_memory_req_i       (data_memory_req),
      .data_memory_req_valid_i (data_memory_req_valid),
      .data_memory_req_ready_o (data_memory_req_ready),
      .data_memory_resp_o      (data_memory_resp),
      .data_memory_resp_valid_o(data_memory_resp_valid),
      .data_memory_resp_ready_i(data_memory_resp_ready),
      .axi_manager_o           (data_axi4_manager_o),
      .axi_manager_i           (data_axi4_manager_i)
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

  always_comb begin
    fence_i_redirect_req                 = '0;
    fence_i_redirect_req.target_pc       = commit.next_pc;
    fence_i_redirect_req.source_pc       = commit.pc;
    fence_i_redirect_req.reason          = REDIRECT_FENCE_I;
    fence_i_redirect_req.flush_inclusive = 1'b0;
  end

  // A synchronous exception reaches the commit boundary but does not retire the
  // faulting instruction. Future multi-commit logic will replace this scalar
  // event with the number of non-trapping instructions retired in this cycle.
  assign retired_instruction_occurred = commit_valid && !commit.trap_taken;

`ifdef NPC_ENABLE_SIM_MONITOR
  // lookup request/response属于IFU与I-cache边界；delivery和waiting属于
  // fetch buffer与IDU边界。分开统计才能区分cache等待与译码反压。
  riscv32_sim_performance_monitor u_sim_performance_monitor (
      .clk_i(clk_i),
      .rst_ni(rst_ni),
      .ifu_instruction_request_occurred_i(icache_lookup_req_valid && icache_lookup_req_ready),
      .ifu_instruction_request_waiting_i(icache_lookup_req_valid && !icache_lookup_req_ready),
      .ifu_instruction_response_occurred_i(icache_lookup_resp_valid && icache_lookup_resp_ready),
      .ifu_instruction_response_discarded_occurred_i(
          icache_lookup_resp_valid && icache_lookup_resp_ready && !ifu_fetch_entry_valid
      ),
      .ifu_instruction_delivery_occurred_i(idu_fetch_entry_valid && idu_fetch_entry_ready),
      .ifu_downstream_waiting_i(idu_fetch_entry_valid && !idu_fetch_entry_ready),
      .instruction_decode_occurred_i(decoded_uop_valid && decoded_uop_ready),
      .decoded_fu_type_i(decoded_uop.fu_type),
      .decoded_memory_cmd_i(decoded_uop.mem_ctrl.cmd),
      .exu_completion_occurred_i(exu_result_valid && exu_result_ready),
      .lsu_completion_occurred_i(lsu_writeback_valid && lsu_writeback_ready),
      .instruction_retirement_occurred_i(retired_instruction_occurred),
      .lsu_request_occurred_i(lsu_req_valid && lsu_req_ready),
      .lsu_request_memory_cmd_i(lsu_req.uop.mem_ctrl.cmd),
      .lsu_read_address_occurred_i(data_axi4_manager_o.ar_valid && data_axi4_manager_i.ar_ready),
      .lsu_read_response_occurred_i(data_axi4_manager_i.r_valid && data_axi4_manager_o.r_ready),
      .lsu_write_address_occurred_i(data_axi4_manager_o.aw_valid && data_axi4_manager_i.aw_ready),
      .lsu_write_data_occurred_i(data_axi4_manager_o.w_valid && data_axi4_manager_i.w_ready),
      .lsu_write_response_occurred_i(data_axi4_manager_i.b_valid && data_axi4_manager_o.b_ready)
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
  assign redirect_req[FENCE_I_REDIRECT_INDEX] = fence_i_redirect_req;
  assign redirect_req_valid[FENCE_I_REDIRECT_INDEX] = committed_fence_i_occurred;

  riscv32_redirect_arbiter #(
      .SOURCE_COUNT(REDIRECT_SOURCE_COUNT)
  ) u_redirect_arbiter (
      .redirect_req_i               (redirect_req),
      .redirect_req_valid_i         (redirect_req_valid),
      .selected_redirect_req_o      (selected_redirect_req),
      .selected_redirect_req_valid_o(selected_redirect_req_valid)
  );

endmodule
