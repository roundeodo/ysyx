// 处理器核连接层：取指 → 译码与操作数准备 → 执行/访存 → 提交 → 恢复。
// 组合运算和状态分别归属子模块；仿真观察逻辑集中在文件末尾。
module riscv32_core
  import riscv_config_pkg::*;
  import riscv32_pkg::*;
  import riscv32_axi4_pkg::*;
#(
    parameter program_counter_t RESET_PC = RESET_VECTOR
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic timer_interrupt_i,

    // 取指和数据访问保持为两个独立manager。系统层负责仲裁和地址路由，
    // core内部不感知SoC拓扑。
    output axi4_manager_to_target_t instruction_axi4_manager_o,
    input  axi4_target_to_manager_t instruction_axi4_manager_i,

    output axi4_manager_to_target_t data_axi4_manager_o,
    input  axi4_target_to_manager_t data_axi4_manager_i
);
  localparam int unsigned REDIRECT_SOURCE_COUNT = 4;
  localparam int unsigned SEQUENTIAL_REDIRECT_INDEX = 0;
  localparam int unsigned EXU_REDIRECT_INDEX = 1;
  localparam int unsigned FENCE_I_REDIRECT_INDEX = 2;
  localparam int unsigned COMMIT_REDIRECT_INDEX = 3;

  icache_lookup_req_t  icache_lookup_req;
  logic                icache_lookup_req_valid;
  logic                icache_lookup_req_ready;
  icache_lookup_resp_t icache_lookup_resp;
  logic                icache_lookup_resp_valid;
  logic                icache_lookup_resp_ready;
  logic                frontend_memory_access_allowed;
  fetch_entry_t        ifu_fetch_entry;
  logic                ifu_fetch_entry_valid;
  logic                ifu_fetch_entry_ready;
  program_counter_t    next_pc_predictor_lookup_request_pc;
  fetch_epoch_t        next_pc_predictor_lookup_request_epoch;
  logic                next_pc_predictor_lookup_request_valid;
  logic                next_pc_predictor_lookup_request_ready;
  program_counter_t    next_pc_predictor_lookup_response_pc;
  fetch_epoch_t        next_pc_predictor_lookup_response_epoch;
  branch_prediction_t  next_pc_predictor_prediction;
  logic                next_pc_predictor_lookup_response_valid;
  logic                next_pc_predictor_lookup_response_ready;
  logic                next_pc_predictor_flush;
  redirect_req_t       selected_redirect_req;
  logic                selected_redirect_req_valid;
  logic                older_redirect_event;
  logic                frontend_prediction_allowed;
  redirect_req_t       sequential_redirect;
  logic                sequential_redirect_valid;

  riscv32_ifu #(
      .PC_START                                 (RESET_PC)
  ) u_ifu (
      .clk_i                                     (clk_i),
      .rst_ni                                    (rst_ni),
      .redirect_req_i                            (selected_redirect_req),
      .redirect_req_valid_i                      (selected_redirect_req_valid),
      .prediction_enable_i                      (frontend_prediction_allowed),
      .next_pc_predictor_lookup_request_pc_o     (next_pc_predictor_lookup_request_pc),
      .next_pc_predictor_lookup_request_epoch_o  (next_pc_predictor_lookup_request_epoch),
      .next_pc_predictor_lookup_request_valid_o  (next_pc_predictor_lookup_request_valid),
      .next_pc_predictor_lookup_request_ready_i  (next_pc_predictor_lookup_request_ready),
      .next_pc_predictor_lookup_response_pc_i    (next_pc_predictor_lookup_response_pc),
      .next_pc_predictor_lookup_response_epoch_i (next_pc_predictor_lookup_response_epoch),
      .next_pc_predictor_prediction_i            (next_pc_predictor_prediction),
      .next_pc_predictor_lookup_response_valid_i (next_pc_predictor_lookup_response_valid),
      .next_pc_predictor_lookup_response_ready_o (next_pc_predictor_lookup_response_ready),
      .next_pc_predictor_flush_o                 (next_pc_predictor_flush),
      .icache_lookup_req_o                       (icache_lookup_req),
      .icache_lookup_req_valid_o                 (icache_lookup_req_valid),
      .icache_lookup_req_ready_i                 (icache_lookup_req_ready && frontend_memory_access_allowed),
      .icache_lookup_resp_i                      (icache_lookup_resp),
      .icache_lookup_resp_valid_i                (icache_lookup_resp_valid),
      .icache_lookup_resp_ready_o                (icache_lookup_resp_ready),
      .fetch_entry_o                             (ifu_fetch_entry),
      .fetch_entry_valid_o                       (ifu_fetch_entry_valid),
      .fetch_entry_ready_i                       (ifu_fetch_entry_ready)
  );

  icache_refill_req_t  icache_refill_req;
  logic                icache_refill_req_valid;
  logic                icache_refill_req_ready;
  icache_refill_resp_t icache_refill_resp;
  logic                icache_refill_resp_valid;
  logic                icache_refill_resp_ready;
  icache_event_t       icache_event;
  logic                icache_invalidate_req;
  logic                icache_invalidate_done;
  logic                icache_busy;

  riscv32_icache u_icache (
      .clk_i                                     (clk_i),
      .rst_ni                                    (rst_ni),
      .lookup_req_i        (icache_lookup_req),
      .lookup_req_valid_i  (icache_lookup_req_valid && frontend_memory_access_allowed),
      .lookup_req_ready_o  (icache_lookup_req_ready),
      .lookup_resp_o       (icache_lookup_resp),
      .lookup_resp_valid_o (icache_lookup_resp_valid),
      .lookup_resp_ready_i (icache_lookup_resp_ready),
      .invalidate_req_i    (icache_invalidate_req),
      .invalidate_done_o   (icache_invalidate_done),
      .cache_busy_o        (icache_busy),
      .refill_req_o        (icache_refill_req),
      .refill_req_valid_o  (icache_refill_req_valid),
      .refill_req_ready_i  (icache_refill_req_ready),
      .refill_resp_i       (icache_refill_resp),
      .refill_resp_valid_i (icache_refill_resp_valid),
      .refill_resp_ready_o (icache_refill_resp_ready),
      .event_o             (icache_event)
  );

  fetch_entry_t idu_fetch_entry;
  logic         idu_fetch_entry_valid;
  logic         idu_fetch_entry_ready;
  logic         frontend_recovery_event;

  riscv32_fetch_buffer u_fetch_buffer (
      .clk_i                                     (clk_i),
      .rst_ni                                    (rst_ni),
      .ifu_fetch_entry_i       (ifu_fetch_entry),
      .ifu_fetch_entry_valid_i (ifu_fetch_entry_valid),
      .ifu_fetch_entry_ready_o (ifu_fetch_entry_ready),
      .idu_fetch_entry_o       (idu_fetch_entry),
      .idu_fetch_entry_valid_o (idu_fetch_entry_valid),
      .idu_fetch_entry_ready_i (idu_fetch_entry_ready),
      .flush_i                 (frontend_recovery_event)
  );

  // 预测器在I-cache之前运行。预测响应与下一次预测请求可以同拍握手；IFU用frontend
  // tag 保存预测元数据；队列 ready 传递容量，预测结果寄存器切断 next-PC 反馈。
  program_counter_t resolved_control_flow_target;
  execute_result_t  resolved_execute_result;

  assign resolved_control_flow_target =
      (resolved_execute_result.uop.branch_ctrl.op == CF_JALR) ?
      resolved_execute_result.next_pc :
      resolved_execute_result.uop.pc +
      program_counter_t'(resolved_execute_result.uop.imm);

  logic resolved_execute_result_valid;
  logic resolved_execute_result_ready;

  riscv32_branch_predictor u_branch_predictor (
      .clk_i                                     (clk_i),
      .rst_ni                                    (rst_ni),
      .lookup_request_pc_i            (next_pc_predictor_lookup_request_pc),
      .lookup_request_epoch_i         (next_pc_predictor_lookup_request_epoch),
      .lookup_request_valid_i         (next_pc_predictor_lookup_request_valid),
      .lookup_request_ready_o         (next_pc_predictor_lookup_request_ready),
      .lookup_response_pc_o           (next_pc_predictor_lookup_response_pc),
      .lookup_response_epoch_o        (next_pc_predictor_lookup_response_epoch),
      .lookup_prediction_o            (next_pc_predictor_prediction),
      .lookup_next_pc_o               (),
      .lookup_response_valid_o        (next_pc_predictor_lookup_response_valid),
      .lookup_response_ready_i        (next_pc_predictor_lookup_response_ready),
      .resolved_control_flow_pc_i     (resolved_execute_result.uop.pc),
      .resolved_control_flow_target_i (resolved_control_flow_target),
      .resolved_control_flow_imm_i    (resolved_execute_result.uop.imm),
      .resolved_control_flow_op_i     (resolved_execute_result.uop.branch_ctrl.op),
      .resolved_control_flow_rs1_i    (resolved_execute_result.uop.rs1),
      .resolved_control_flow_rd_i     (resolved_execute_result.uop.rd),
      .resolved_control_flow_event_i  (
          resolved_execute_result_valid && resolved_execute_result_ready &&
          (resolved_execute_result.uop.fu_type == FU_BRANCH) &&
          !resolved_execute_result.uop.exception_valid
      ),
      .resolved_control_flow_taken_i(
          (resolved_execute_result.uop.branch_ctrl.op != CF_BRANCH) ||
          (resolved_execute_result.next_pc !=
          (resolved_execute_result.uop.pc + program_counter_t'(INSTRUCTION_BYTES)))
      ),
      .flush_lookup_i (next_pc_predictor_flush),
      .invalidate_i   (icache_invalidate_req)
  );

  // 统计真正随fetch entry进入队列的taken预测，不统计尚未完成I-cache响应配对的请求。
  logic fetch_taken_prediction_event;

  assign fetch_taken_prediction_event =
      ifu_fetch_entry_valid && ifu_fetch_entry_ready &&
      ifu_fetch_entry.prediction.predicted_taken;

  riscv32_icache_axi u_icache_axi (
      .clk_i                                     (clk_i),
      .rst_ni                                    (rst_ni),
      .refill_req_i        (icache_refill_req),
      .refill_req_valid_i  (icache_refill_req_valid),
      .refill_req_ready_o  (icache_refill_req_ready),
      .refill_resp_o       (icache_refill_resp),
      .refill_resp_valid_o (icache_refill_resp_valid),
      .refill_resp_ready_i (icache_refill_resp_ready),
      .axi_manager_o       (instruction_axi4_manager_o),
      .axi_manager_i       (instruction_axi4_manager_i)
  );

  decoded_uop_t decoded_uop;
  logic         decoded_uop_valid;
  logic         decoded_uop_ready;

  riscv32_idu u_idu (
      // IDU反压先由fetch queue吸收；队列填满后才会向IFU和I-cache传播。
      .fetch_entry_i       (idu_fetch_entry),
      .fetch_entry_valid_i (idu_fetch_entry_valid),
      .fetch_entry_ready_o (idu_fetch_entry_ready),
      .decoded_uop_o      (decoded_uop),
      .decoded_uop_valid_o(decoded_uop_valid),
      .decoded_uop_ready_i(decoded_uop_ready)
  );

  xlen_data_t    rs1_value;
  xlen_data_t    rs2_value;
  xlen_data_t    gpr_write_data;
  arch_reg_idx_t gpr_write_addr;
  logic          gpr_write_enable;

  riscv32_regfile u_regfile (
      .clk_i                                     (clk_i),
      .gpr_write_data_i   (gpr_write_data),
      .gpr_write_addr_i   (gpr_write_addr),
      .gpr_write_enable_i (gpr_write_enable),
      .rs1_addr_i         (decoded_uop.rs1),
      .rs1_data_o         (rs1_value),
      .rs2_addr_i         (decoded_uop.rs2),
      .rs2_data_o         (rs2_value)
  );

  commit_t          commit;
  logic             commit_valid;
  xlen_data_t       csr_read_data;
  logic             csr_read_illegal;
  program_counter_t csr_mtvec;
  program_counter_t csr_mepc;
  logic             retired_instruction_event;
  logic             timer_interrupt_enabled;
  logic             trap_valid;
  program_counter_t trap_pc;
  xlen_data_t       trap_cause;
  xlen_data_t       trap_tval;
  logic             mret_valid;

  riscv32_csr_file u_csr_file (
      .clk_i                                     (clk_i),
      .rst_ni                                    (rst_ni),
      .csr_read_enable_i (decoded_uop_valid && decoded_uop.csr_ctrl.read_enable),
      // CSR地址是固定指令字段，可与opcode译码并行选择；使能仍由合法译码产生。
      .csr_read_addr_i             (idu_fetch_entry.instruction[31:20]),
      .csr_access_write_enable_i   (decoded_uop_valid && decoded_uop.csr_ctrl.write_enable),
      .csr_read_data_o             (csr_read_data),
      .csr_read_illegal_o          (csr_read_illegal),
      .csr_write_valid_i           (commit_valid && commit.csr_write),
      .csr_write_addr_i            (commit.csr_addr),
      .csr_write_data_i            (commit.csr_wdata),
      .retired_instruction_event_i (retired_instruction_event),
      .trap_valid_i                (trap_valid),
      .trap_pc_i                   (trap_pc),
      .trap_cause_i                (trap_cause),
      .trap_tval_i                 (trap_tval),
      .mret_valid_i                (mret_valid),
      .timer_interrupt_i           (timer_interrupt_i),
      .timer_interrupt_enabled_o   (timer_interrupt_enabled),
      .mtvec_o                     (csr_mtvec),
      .mepc_o                      (csr_mepc)
  );

  // 冒险比较和前递选择：执行、结果级与 WB 的反馈在此汇合。
  logic execute_result_forwarding_available;

  writeback_result_t writeback_result;
  logic              writeback_result_valid;
  logic              writeback_forwarding_available;

  execute_packet_t   execute_packet;
  logic              execute_packet_valid;
  writeback_result_t lsu_writeback;
  logic              lsu_writeback_valid;
  logic              lsu_writeback_ready;
  logic              decode_accept_allowed;
  logic              execute_progress_allowed;
  logic              execute_issue_allowed;
  logic              decode_execute_flush;
  logic              writeback_flush;
  logic              raw_hazard_present;
  logic              serializing_hazard_present;
  logic              structural_hazard_present;
  logic              lsu_transaction_active;
  logic              lsu_pending_writes_rd;
  arch_reg_idx_t     lsu_pending_rd;
  logic              commit_redirect_event;
  logic              execute_forwardable_producer_present;
  logic              execute_blocking_producer_present;
  logic              execute_serializing_instruction_present;
  logic              rs1_execute_forwarding_selected;
  logic              rs1_execute_result_forwarding_selected;
  logic              rs1_lsu_forwarding_selected;
  logic              rs1_writeback_forwarding_selected;
  logic              rs2_execute_forwarding_selected;
  logic              rs2_execute_result_forwarding_selected;
  logic              rs2_lsu_forwarding_selected;
  logic              rs2_writeback_forwarding_selected;

  assign execute_result_forwarding_available = resolved_execute_result_valid &&
      resolved_execute_result.uop.writes_rd &&
      !resolved_execute_result.uop.exception_valid;
  assign writeback_forwarding_available = writeback_result_valid &&
      writeback_result.uop.writes_rd &&
      !writeback_result.uop.exception_valid;

  riscv32_hazard_ctrl u_hazard_ctrl (
      .clk_i                                     (clk_i),
      .rst_ni                                    (rst_ni),
      .decoded_uop_valid_i                       (decoded_uop_valid),
      .decoded_uses_rs1_i                        (decoded_uop.uses_rs1),
      .decoded_rs1_i                             (decoded_uop.rs1),
      .decoded_uses_rs2_i                        (decoded_uop.uses_rs2),
      .decoded_rs2_i                             (decoded_uop.rs2),
      .decoded_serializing_i                     (decoded_uop.serializing),
      .execute_instruction_present_i             (execute_packet_valid),
      .execute_forwardable_producer_present_i    (execute_forwardable_producer_present),
      .execute_blocking_producer_present_i       (execute_blocking_producer_present),
      .execute_rd_i                              (execute_packet.uop.rd),
      .execute_serializing_instruction_present_i (execute_serializing_instruction_present),
      .execute_result_valid_i                    (resolved_execute_result_valid),
      .execute_result_ready_i                    (resolved_execute_result_ready),
      .execute_result_exception_valid_i          (resolved_execute_result.uop.exception_valid),
      .execute_result_writes_rd_i                (resolved_execute_result.uop.writes_rd),
      .execute_result_rd_i                       (resolved_execute_result.uop.rd),
      .execute_result_forwarding_available_i     (execute_result_forwarding_available),
      .execute_result_serializing_i              (resolved_execute_result.uop.serializing),
      .writeback_result_valid_i                  (writeback_result_valid),
      .writeback_writes_rd_i                     (writeback_result.uop.writes_rd),
      .writeback_rd_i                            (writeback_result.uop.rd),
      .writeback_serializing_i                   (writeback_result.uop.serializing),
      .writeback_forwarding_available_i          (writeback_forwarding_available),
      .lsu_busy_i                                (lsu_transaction_active),
      .lsu_completion_succeeded_i                (
          lsu_writeback_valid && lsu_writeback_ready &&
          !lsu_writeback.uop.exception_valid
      ),
      .lsu_pending_writes_rd_i    (lsu_pending_writes_rd),
      .lsu_pending_rd_i           (lsu_pending_rd),
      .execute_redirect_present_i (
          resolved_execute_result_valid &&
          resolved_execute_result.redirect_valid
      ),
      .frontend_redirect_applied_i              (older_redirect_event),
      .commit_redirect_event_i                  (commit_redirect_event),
      .decode_accept_allowed_o                  (decode_accept_allowed),
      .execute_progress_allowed_o               (execute_progress_allowed),
      .execute_issue_allowed_o                  (execute_issue_allowed),
      .decode_execute_flush_o                   (decode_execute_flush),
      .writeback_flush_o                        (writeback_flush),
      .raw_hazard_present_o                     (raw_hazard_present),
      .serializing_hazard_present_o             (serializing_hazard_present),
      .structural_hazard_present_o              (structural_hazard_present),
      .rs1_execute_forwarding_selected_o        (rs1_execute_forwarding_selected),
      .rs1_execute_result_forwarding_selected_o (rs1_execute_result_forwarding_selected),
      .rs1_lsu_forwarding_selected_o            (rs1_lsu_forwarding_selected),
      .rs1_writeback_forwarding_selected_o      (rs1_writeback_forwarding_selected),
      .rs2_execute_forwarding_selected_o        (rs2_execute_forwarding_selected),
      .rs2_execute_result_forwarding_selected_o (rs2_execute_result_forwarding_selected),
      .rs2_lsu_forwarding_selected_o            (rs2_lsu_forwarding_selected),
      .rs2_writeback_forwarding_selected_o      (rs2_writeback_forwarding_selected)
  );

  execute_packet_t decoded_execute_packet;
  execute_result_t exu_result;

  riscv32_operand_mux u_operand_mux (
      .decoded_uop_i                            (decoded_uop),
      .rs1_value_i                              (rs1_value),
      .rs2_value_i                              (rs2_value),
      .csr_read_data_i                          (csr_read_data),
      .csr_read_illegal_i                       (csr_read_illegal),
      .execute_forwarding_value_i               (exu_result.result),
      .execute_result_forwarding_value_i        (resolved_execute_result.result),
      .lsu_forwarding_value_i                   (lsu_writeback.result),
      .writeback_forwarding_value_i             (writeback_result.result),
      .rs1_execute_forwarding_selected_i        (rs1_execute_forwarding_selected),
      .rs1_execute_result_forwarding_selected_i (rs1_execute_result_forwarding_selected),
      .rs1_lsu_forwarding_selected_i            (rs1_lsu_forwarding_selected),
      .rs1_writeback_forwarding_selected_i      (rs1_writeback_forwarding_selected),
      .rs2_execute_forwarding_selected_i        (rs2_execute_forwarding_selected),
      .rs2_execute_result_forwarding_selected_i (rs2_execute_result_forwarding_selected),
      .rs2_lsu_forwarding_selected_i            (rs2_lsu_forwarding_selected),
      .rs2_writeback_forwarding_selected_i      (rs2_writeback_forwarding_selected),
      .decoded_execute_packet_o                 (decoded_execute_packet)
  );

  // valid和ready同时受冒险策略约束，保证被停顿的fetch entry仍由fetch buffer持有，
  // 不会出现“stage没有保存，但上游认为已经交付”的消息丢失。

  logic decoded_execute_packet_valid;
  logic interrupt_issue_hold;
  logic decoded_execute_packet_ready;
  logic execute_packet_ready;

  assign decoded_execute_packet_valid = decoded_uop_valid && decode_accept_allowed &&
      !interrupt_issue_hold;

  assign decoded_uop_ready = decoded_execute_packet_ready && decode_accept_allowed &&
      !interrupt_issue_hold;

  riscv32_id_ex_reg u_id_ex_reg (
      .clk_i                                     (clk_i),
      .rst_ni                                    (rst_ni),
      .decoded_execute_packet_i                  (decoded_execute_packet),
      .decoded_execute_packet_valid_i            (decoded_execute_packet_valid),
      .decoded_execute_packet_ready_o            (decoded_execute_packet_ready),
      .execute_packet_o                          (execute_packet),
      .execute_packet_valid_o                    (execute_packet_valid),
      .execute_packet_ready_i                    (execute_packet_ready && execute_progress_allowed),
      .execute_forwardable_producer_present_o    (execute_forwardable_producer_present),
      .execute_blocking_producer_present_o       (execute_blocking_producer_present),
      .execute_serializing_instruction_present_o (execute_serializing_instruction_present),
      .flush_i                                   (decode_execute_flush || sequential_redirect_valid)
  );

  logic     exu_result_valid;
  logic     exu_result_ready;
  lsu_req_t lsu_req;
  logic     lsu_req_valid;
  logic     lsu_req_ready;

  riscv32_exu u_exu (
      .execute_packet_i               (execute_packet),
      .execute_packet_valid_i         (execute_packet_valid),
      .execute_packet_issue_allowed_i (execute_issue_allowed),
      .execute_packet_ready_o         (execute_packet_ready),
      .exu_result_o                   (exu_result),
      .exu_result_valid_o             (exu_result_valid),
      .exu_result_ready_i             (exu_result_ready),
      .lsu_req_o                      (lsu_req),
      .lsu_req_valid_o                (lsu_req_valid),
      .lsu_req_ready_i                (lsu_req_ready),
      .sequential_redirect_o         (sequential_redirect),
      .sequential_redirect_valid_o   (sequential_redirect_valid)
  );

  // EX1在EXU中计算真实结果，EX2从本寄存级校验控制流预测。普通整数结果可滚动通过；
  // 本级寄存结果送回操作数准备模块，在下一条消费者进入 ID/EX 时完成前递。
  logic execute_redirect_resolution_event;

  riscv32_ex_result_reg u_ex_result_reg (
      .clk_i                                     (clk_i),
      .rst_ni                                    (rst_ni),
      .executed_result_i       (exu_result),
      .executed_result_valid_i (exu_result_valid),
      .executed_result_ready_o (exu_result_ready),
      .resolved_result_o       (resolved_execute_result),
      .resolved_result_valid_o (resolved_execute_result_valid),
      .resolved_result_ready_i (resolved_execute_result_ready),
      // 执行级分支恢复取消同拍进入EX/MEM的更年轻普通结果；提交级恢复处理异常、
      // mret；FENCE.I 依靠串行化排空后端。flush 只清本级 valid。
      .flush_i                (execute_redirect_resolution_event || commit_redirect_event)
  );

  data_memory_req_t  data_memory_req;
  logic              data_memory_req_valid;
  logic              data_memory_req_ready;
  data_memory_resp_t data_memory_resp;
  logic              data_memory_resp_valid;
  logic              data_memory_resp_ready;

  riscv32_lsu u_lsu (
      .clk_i                                     (clk_i),
      .rst_ni                                    (rst_ni),
      .lsu_req_i                (lsu_req),
      .lsu_req_valid_i          (lsu_req_valid),
      .lsu_req_ready_o          (lsu_req_ready),
      .lsu_transaction_active_o (lsu_transaction_active),
      .lsu_pending_writes_rd_o  (lsu_pending_writes_rd),
      .lsu_pending_rd_o         (lsu_pending_rd),
      .lsu_writeback_o          (lsu_writeback),
      .lsu_writeback_valid_o    (lsu_writeback_valid),
      .lsu_writeback_ready_i    (lsu_writeback_ready),
      .data_memory_req_o        (data_memory_req),
      .data_memory_req_valid_o  (data_memory_req_valid),
      .data_memory_req_ready_i  (data_memory_req_ready),
      .data_memory_resp_i       (data_memory_resp),
      .data_memory_resp_valid_i (data_memory_resp_valid),
      .data_memory_resp_ready_o (data_memory_resp_ready)
  );

  dcache_event_t dcache_event;
  logic          dcache_clean_req;
  logic          dcache_clean_done;
  logic          dcache_clean_access_fault;
  logic          dcache_busy;

  riscv32_data_mem u_data_mem (
      .clk_i                                     (clk_i),
      .rst_ni                                    (rst_ni),
      .data_memory_req_i           (data_memory_req),
      .data_memory_req_valid_i     (data_memory_req_valid),
      .data_memory_req_ready_o     (data_memory_req_ready),
      .data_memory_resp_o          (data_memory_resp),
      .data_memory_resp_valid_o    (data_memory_resp_valid),
      .data_memory_resp_ready_i    (data_memory_resp_ready),
      .dcache_clean_req_i          (dcache_clean_req),
      .dcache_clean_done_o         (dcache_clean_done),
      .dcache_clean_access_fault_o (dcache_clean_access_fault),
      .dcache_busy_o               (dcache_busy),
      .dcache_event_o              (dcache_event),
      .axi_manager_o               (data_axi4_manager_o),
      .axi_manager_i               (data_axi4_manager_i)
  );

  writeback_result_t completion_result;
  logic              completion_result_valid;
  logic              completion_result_ready;

  riscv32_completion_mux u_completion_mux (
      .exu_result_i             (resolved_execute_result),
      .exu_result_valid_i       (resolved_execute_result_valid),
      .exu_result_ready_o       (resolved_execute_result_ready),
      .lsu_writeback_i          (lsu_writeback),
      .lsu_writeback_valid_i    (lsu_writeback_valid),
      .lsu_writeback_ready_o    (lsu_writeback_ready),
      .writeback_result_o       (completion_result),
      .writeback_result_valid_o (completion_result_valid),
      .writeback_result_ready_i (completion_result_ready)
  );

  // EXU/LSU completion先进入WB弹性寄存器，再由commit产生唯一架构事件。
  // 这既切断执行到寄存器堆的长组合路径，也让Difftest只观察稳定的退休级payload。
  logic writeback_result_ready;

  riscv32_wb_reg u_wb_reg (
      .clk_i                                     (clk_i),
      .rst_ni                                    (rst_ni),
      .completion_result_i       (completion_result),
      .completion_result_valid_i (completion_result_valid),
      .completion_result_ready_o (completion_result_ready),
      .writeback_result_o        (writeback_result),
      .writeback_result_valid_o  (writeback_result_valid),
      .writeback_result_ready_i  (writeback_result_ready),
      .flush_i                   (writeback_flush)
  );

  riscv32_commit u_commit (
      .writeback_result_i       (writeback_result),
      .writeback_result_valid_i                  (writeback_result_valid),
      .writeback_result_ready_o (writeback_result_ready),
      .commit_o                 (commit),
      .commit_valid_o           (commit_valid),
      .gpr_write_data_o         (gpr_write_data),
      .gpr_write_addr_o         (gpr_write_addr),
      .gpr_write_enable_o       (gpr_write_enable)
  );

  // 发生同步异常的指令到达提交边界，但不计入退休指令数。
  assign retired_instruction_event = commit_valid && !commit.trap_taken;

  // 提交后的缓存维护与前端恢复。
  logic          fence_i_maintenance_active;
  logic          fence_i_failed;
  logic          committed_fence_i_event;
  redirect_req_t fence_i_redirect_req;

  riscv32_fence_i_ctrl u_fence_i_ctrl (
      .clk_i                                     (clk_i),
      .rst_ni                                    (rst_ni),
      .commit_valid_i                   (commit_valid),
      .commit_i                         (commit),
      .icache_lookup_req_valid_i        (icache_lookup_req_valid),
      .icache_lookup_req_ready_i        (icache_lookup_req_ready),
      .icache_busy_i                    (icache_busy),
      .dcache_clean_done_i              (dcache_clean_done),
      .dcache_clean_access_fault_i      (dcache_clean_access_fault),
      .icache_invalidate_done_i         (icache_invalidate_done),
      .committed_fence_i_event_o        (committed_fence_i_event),
      .fence_i_redirect_req_o           (fence_i_redirect_req),
      .fence_i_maintenance_active_o     (fence_i_maintenance_active),
      .frontend_memory_access_allowed_o (frontend_memory_access_allowed),
      .frontend_prediction_allowed_o    (frontend_prediction_allowed),
      .maintenance_failed_o             (fence_i_failed),
      .dcache_clean_req_o               (dcache_clean_req),
      .icache_invalidate_req_o          (icache_invalidate_req)
  );

  redirect_req_t    commit_redirect_req_at_resolution;
  logic             commit_redirect_resolution_event;
  logic             interrupt_valid;
  program_counter_t interrupt_pc;

  // 中断在 ID/EX 入口暂停新工作，等待后端和缓存维护排空后受理。
  riscv32_interrupt_ctrl #(
      .RESET_PC                 (RESET_PC)
  ) u_interrupt_ctrl (
      .clk_i                                     (clk_i),
      .rst_ni                                    (rst_ni),
      .timer_interrupt_enabled_i (timer_interrupt_enabled),
      .backend_busy_i            (
          execute_packet_valid || resolved_execute_result_valid ||
          lsu_transaction_active || writeback_result_valid
      ),
      .maintenance_busy_i (fence_i_maintenance_active || dcache_busy),
      .commit_valid_i                   (commit_valid),
      .commit_i                         (commit),
      .redirect_valid_i   (commit_redirect_resolution_event),
      .redirect_i         (commit_redirect_req_at_resolution),
      .issue_hold_o       (interrupt_issue_hold),
      .interrupt_valid_o  (interrupt_valid),
      .interrupt_pc_o     (interrupt_pc)
  );

  riscv32_trap_ctrl u_trap_ctrl (
      .commit_i                         (commit),
      .commit_valid_i                   (commit_valid),
      .interrupt_valid_i    (interrupt_valid),
      .interrupt_pc_i       (interrupt_pc),
      .mtvec_i              (csr_mtvec),
      .mepc_i               (csr_mepc),
      .trap_valid_o         (trap_valid),
      .trap_pc_o            (trap_pc),
      .trap_cause_o         (trap_cause),
      .trap_tval_o          (trap_tval),
      .mret_valid_o         (mret_valid),
      .redirect_req_o       (commit_redirect_req_at_resolution),
      .redirect_req_valid_o (commit_redirect_resolution_event)
  );

  redirect_req_t execute_redirect_req_at_resolution;

  assign execute_redirect_req_at_resolution = resolved_execute_result.redirect_req;
  assign execute_redirect_resolution_event  =
      resolved_execute_result_valid && resolved_execute_result_ready &&
      resolved_execute_result.redirect_valid;

  // 提交恢复优先于 FENCE.I，再优先于分支修正；同拍直接送达前端与 flush。
  redirect_req_t                    redirect_req_at_resolution_array[REDIRECT_SOURCE_COUNT];
  logic [REDIRECT_SOURCE_COUNT-1:0] redirect_req_at_resolution_valid_vector;

  // 当前 EXU 非分支纠错只清年轻项，不能反馈阻塞自己的交付或清掉自己的结果。
  assign older_redirect_event = execute_redirect_resolution_event ||
      committed_fence_i_event || commit_redirect_resolution_event;
  assign redirect_req_at_resolution_array[SEQUENTIAL_REDIRECT_INDEX] = sequential_redirect;
  assign redirect_req_at_resolution_valid_vector[SEQUENTIAL_REDIRECT_INDEX] = sequential_redirect_valid;
  assign redirect_req_at_resolution_array[EXU_REDIRECT_INDEX] = execute_redirect_req_at_resolution;

  assign redirect_req_at_resolution_valid_vector[EXU_REDIRECT_INDEX] =
      execute_redirect_resolution_event;
  assign redirect_req_at_resolution_array[FENCE_I_REDIRECT_INDEX] = fence_i_redirect_req;
  assign redirect_req_at_resolution_valid_vector[FENCE_I_REDIRECT_INDEX] = committed_fence_i_event;
  assign redirect_req_at_resolution_array[COMMIT_REDIRECT_INDEX] =
      commit_redirect_req_at_resolution;
  assign redirect_req_at_resolution_valid_vector[COMMIT_REDIRECT_INDEX] =
      commit_redirect_resolution_event;

  riscv32_redirect_mux #(
      .SOURCE_COUNT                   (REDIRECT_SOURCE_COUNT)
  ) u_redirect_mux (
      .redirect_req_i                  (redirect_req_at_resolution_array),
      .redirect_req_valid_i            (redirect_req_at_resolution_valid_vector),
      .redirect_req_o                  (selected_redirect_req),
      .redirect_req_valid_o            (selected_redirect_req_valid)
  );

  // trap/mret必须在提交边界立即清除更年轻的后端工作。FENCE.I已经被IDU标记为
  // serializing：它只有在所有老指令排空后才能进入，且在自己提交前不会接收年轻指令，
  // 因此提交拍不需要再通过通用commit flush组合地kill LSU。FENCE.I的前端恢复仍经过
  // u_redirect_mux，并与D-cache clean、I-cache invalidate维护状态机协同。
  // 将两类事件分开也避免commit -> LSU -> D-cache array的跨模块关键路径。
  assign commit_redirect_event   = commit_redirect_resolution_event;
  assign frontend_recovery_event = selected_redirect_req_valid;

`ifdef NPC_ENABLE_SIM_MONITOR
  logic [63:0] sim_icache_cacheable_hit_count;
  logic [63:0] sim_icache_cacheable_miss_response_count;
  logic [63:0] sim_icache_hit_latency_cycle_sum;
  logic [63:0] sim_icache_miss_response_latency_cycle_sum;
`endif

`ifdef NPC_ENABLE_SIM_MONITOR
  riscv32_sim_issue_window_monitor u_sim_issue_window_monitor (
      .clk_i                                     (clk_i),
      .rst_ni                                    (rst_ni),
      .commit_valid_i                   (commit_valid),
      .commit_i                         (commit),
      .issue_event_i                ((exu_result_valid && exu_result_ready) || (lsu_req_valid && lsu_req_ready)),
      .execute_valid_i              (execute_packet_valid),
      .redirect_event_i             (execute_redirect_resolution_event || commit_redirect_event),
      .lsu_busy_i                                (lsu_transaction_active),
      .execute_result_blocked_i     (resolved_execute_result_valid && !resolved_execute_result_ready),
      .register_read_valid_i        (decoded_uop_valid),
      .raw_hazard_present_i         (raw_hazard_present),
      .serializing_hazard_present_i (serializing_hazard_present),
      .icache_event_i               (icache_event),
      .dcache_event_i               (dcache_event)
  );

  // lookup request/response属于IFU与I-cache边界；delivery和waiting属于IFU与IDU边界。
  // 分开统计才能区分cache等待与译码反压。
  riscv32_sim_perf_monitor u_sim_perf_monitor (
      .clk_i                                     (clk_i),
      .rst_ni                                    (rst_ni),
      .ifu_instruction_request_event_i (
          icache_lookup_req_valid && icache_lookup_req_ready && frontend_memory_access_allowed
      ),
      .ifu_instruction_request_waiting_i(
          icache_lookup_req_valid &&
          (!icache_lookup_req_ready || !frontend_memory_access_allowed)
      ),
      .ifu_instruction_response_event_i           (icache_lookup_resp_valid && icache_lookup_resp_ready),
      .ifu_instruction_response_discarded_event_i (
          icache_lookup_resp_valid && icache_lookup_resp_ready && !ifu_fetch_entry_valid
      ),
      .ifu_instruction_delivery_event_i (idu_fetch_entry_valid && idu_fetch_entry_ready),
      .ifu_downstream_waiting_i         (idu_fetch_entry_valid && !idu_fetch_entry_ready),
      .icache_miss_event_i              (icache_event.miss_event),
      .instruction_decode_event_i(decoded_uop_valid && decoded_uop_ready),
      .decoded_fu_type_i(decoded_uop.fu_type),
      .decoded_memory_cmd_i(decoded_uop.mem_ctrl.cmd),
      .exu_completion_event_i(resolved_execute_result_valid && resolved_execute_result_ready),
      .lsu_completion_event_i         (lsu_writeback_valid && lsu_writeback_ready),
      .instruction_retirement_event_i (retired_instruction_event),
      .pipeline_raw_hazard_waiting_i  (raw_hazard_present),
      .pipeline_serializing_waiting_i (serializing_hazard_present),
      .pipeline_structural_waiting_i  (structural_hazard_present && decoded_uop_valid),
      .frontend_supply_waiting_i      (
          !decoded_uop_valid && !structural_hazard_present &&
          !commit_redirect_event
      ),
      .pipeline_control_flush_event_i           (frontend_recovery_event),
      .pipeline_execute_instruction_discarded_i (commit_redirect_event && execute_packet_valid),
      .fetch_taken_prediction_event_i           (fetch_taken_prediction_event),
      // 纠错事件和控制流字段必须来自同一条 EX 结果，
      // 不能与当前 EXU 中下一条指令的字段配对。
      .execute_misprediction_redirect_event_i (execute_redirect_resolution_event),
      .control_flow_resolution_event_i        (
          resolved_execute_result_valid && resolved_execute_result_ready &&
          (resolved_execute_result.uop.fu_type == FU_BRANCH) &&
          !resolved_execute_result.uop.exception_valid
      ),
      .resolved_control_flow_op_i     (resolved_execute_result.uop.branch_ctrl.op),
      .resolved_control_flow_pc_i     (resolved_execute_result.uop.pc),
      .resolved_control_flow_taken_i(
          (resolved_execute_result.uop.branch_ctrl.op != CF_BRANCH) ||
          (resolved_execute_result.next_pc !=
          (resolved_execute_result.uop.pc + program_counter_t'(INSTRUCTION_BYTES)))
      ),
      .resolved_control_flow_immediate_i        (resolved_execute_result.uop.imm),
      .lsu_request_event_i                      (lsu_req_valid && lsu_req_ready),
      .lsu_request_memory_cmd_i                 (lsu_req.uop.mem_ctrl.cmd),
      .lsu_read_address_event_i                 (data_axi4_manager_o.ar_valid && data_axi4_manager_i.ar_ready),
      .lsu_read_response_event_i                (data_axi4_manager_i.r_valid && data_axi4_manager_o.r_ready),
      .lsu_write_address_event_i                (data_axi4_manager_o.aw_valid && data_axi4_manager_i.aw_ready),
      .lsu_write_data_event_i                   (data_axi4_manager_o.w_valid && data_axi4_manager_i.w_ready),
      .lsu_write_response_event_i               (data_axi4_manager_i.b_valid && data_axi4_manager_o.b_ready),
      .icache_cacheable_hit_count_i             (sim_icache_cacheable_hit_count),
      .icache_cacheable_miss_response_count_i   (sim_icache_cacheable_miss_response_count),
      .icache_hit_latency_cycle_sum_i           (sim_icache_hit_latency_cycle_sum),
      .icache_miss_response_latency_cycle_sum_i (sim_icache_miss_response_latency_cycle_sum)
  );

  // Cache性能统计只存在于仿真配置。它观察I-cache定义的语义事件，不从AXI
  // beat反推hit/miss，因此不会把一次cache line refill误计成多次miss。
  riscv32_sim_icache_monitor u_sim_icache_monitor (
      .clk_i                                     (clk_i),
      .rst_ni                                    (rst_ni),
      .icache_event_i               (icache_event),
      .cacheable_hit_count_o             (sim_icache_cacheable_hit_count),
      .cacheable_miss_response_count_o   (sim_icache_cacheable_miss_response_count),
      .hit_latency_cycle_sum_o           (sim_icache_hit_latency_cycle_sum),
      .miss_response_latency_cycle_sum_o (sim_icache_miss_response_latency_cycle_sum)
  );

  // D-cache监视器直接消费cache语义事件，不根据AXI beat反推hit/miss。这样一条
  // cache-line refill仍然只对应一次需求miss，并可独立观察脏替换写回成本。
  riscv32_sim_dcache_monitor u_sim_dcache_monitor (
      .clk_i                                     (clk_i),
      .rst_ni                                    (rst_ni),
      .dcache_event_i               (dcache_event)
  );
`endif

`ifndef SYNTHESIS
  // rst_ni是状态寄存器的异步复位，同时也是SVA的disable条件。Verilator会把后者
  // 视为同步使用并报告SYNCASYNCNET；该诊断不代表复位网络存在功能冲突。
  /* verilator lint_off SYNCASYNCNET */
  a_interrupt_has_no_instruction_side_effects :
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    interrupt_valid |-> (!commit_valid && !execute_packet_valid &&
                         !resolved_execute_result_valid && !lsu_transaction_active &&
                         !lsu_req_valid && !gpr_write_enable && !decoded_execute_packet_valid))
  else
    $error("interrupt accepted before the execution pipeline drained");

  // fence.i维护请求按D-cache clean、I-cache invalidate的固定顺序保持到完成。
  a_dcache_clean_request_held_until_done :
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (dcache_clean_req && !dcache_clean_done) |=> dcache_clean_req)
  else
    $error("core withdrew D-cache clean request before completion");

  a_icache_invalidate_request_held_until_done :
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (icache_invalidate_req && !icache_invalidate_done) |=> icache_invalidate_req)
  else
    $error("core withdrew I-cache invalidate request before completion");

  a_icache_invalidate_done_has_request :
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    icache_invalidate_done |-> icache_invalidate_req)
  else
    $error("core observed I-cache invalidate completion without a request");

  a_icache_invalidate_request_means_busy :
  assert property (@(posedge clk_i) disable iff (!rst_ni) icache_invalidate_req |-> icache_busy)
  else
    $error("I-cache dropped busy while an invalidate transaction was pending");

  a_dcache_clean_request_means_busy :
  assert property (@(posedge clk_i) disable iff (!rst_ni) dcache_clean_req |-> dcache_busy)
  else
    $error("D-cache dropped busy while a clean transaction was pending");

  a_dcache_clean_fault_stops_execution :
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (dcache_clean_req && dcache_clean_done && dcache_clean_access_fault) |=> fence_i_failed)
  else $error("FENCE.I clean error did not enter the failed state");

  a_failed_maintenance_has_no_side_effects :
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    fence_i_failed |-> (!commit_valid && !lsu_req_valid && !icache_invalidate_req &&
                       !next_pc_predictor_lookup_request_valid && !interrupt_valid))
  else $error("Core continued execution after fatal FENCE.I maintenance error");

  // FENCE.I依靠serializing语义排空后端，而不是在提交拍用组合flush补救。该性质成立时，
  // committed_fence_i_event 同拍发起重定向，并启动 cache 维护事务。
  a_committed_fence_i_has_no_younger_backend_work :
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    committed_fence_i_event |->
    (!execute_packet_valid && !resolved_execute_result_valid && !lsu_transaction_active))
  else
    $error("FENCE.I committed while younger backend work was still present");

  // 老异常在 EX 结果级时就阻止年轻 LSU 请求，不能等到 WB 恢复再取消已接收的访存。
  a_execute_exception_blocks_younger_memory :
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (resolved_execute_result_valid && resolved_execute_result.uop.exception_valid) |->
      (!execute_progress_allowed && !execute_issue_allowed && !lsu_req_valid))
  else
    $error("older EX result exception allowed a younger memory request");

  // 精确异常在 commit 成为架构事件，此时也不能残留此前接收的年轻 LSU 事务。
  a_committed_exception_flushes_younger_instructions :
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (commit_valid && commit.trap_taken) |->
    (commit_redirect_event && decode_execute_flush && writeback_flush &&
     !execute_issue_allowed && !lsu_transaction_active))
  else
    $error("committed exception did not block and flush younger pipeline work");

  // 只有 LSU 已成功交付 WB，才允许年轻普通指令在同拍进入空 EX 结果级。
  a_lsu_completion_overlap_preserves_order :
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (lsu_transaction_active && exu_result_valid && exu_result_ready) |->
    (lsu_writeback_valid && lsu_writeback_ready && !lsu_writeback.uop.exception_valid &&
     !resolved_execute_result_valid))
  else
    $error("younger execution crossed an unfinished or faulting LSU transaction");

  a_resolved_execute_redirect_blocks_younger_execute :
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (resolved_execute_result_valid && resolved_execute_result.redirect_valid) |->
      (decode_execute_flush && !execute_issue_allowed && !lsu_req_valid))
  else
    $error("resolved execute redirect allowed a wrong-path EX side effect");

  /* verilator lint_on SYNCASYNCNET */
`endif

endmodule
