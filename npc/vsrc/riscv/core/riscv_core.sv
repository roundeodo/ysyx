// 处理器核连接层：取指 → 译码与操作数准备 → 执行/访存 → 提交 → 恢复。
// 单发射按序进入功能单元，scoreboard 接收乱序完成并按序交给 commit。
module riscv_core
  import riscv_config_pkg::*;
  import riscv_pkg::*;
  import riscv_axi4_pkg::*;
#(
    parameter program_counter_t RESET_PC = RESET_VECTOR
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

  riscv_ifu #(
      .PC_START(RESET_PC)
  ) u_ifu (
      .clk_i(clk_i),
      .rst_ni(rst_ni),
      .redirect_req_i(selected_redirect_req),
      .redirect_req_valid_i(selected_redirect_req_valid),
      .prediction_enable_i(frontend_prediction_allowed),
      .next_pc_predictor_lookup_request_pc_o(next_pc_predictor_lookup_request_pc),
      .next_pc_predictor_lookup_request_epoch_o(next_pc_predictor_lookup_request_epoch),
      .next_pc_predictor_lookup_request_valid_o(next_pc_predictor_lookup_request_valid),
      .next_pc_predictor_lookup_request_ready_i(next_pc_predictor_lookup_request_ready),
      .next_pc_predictor_lookup_response_pc_i(next_pc_predictor_lookup_response_pc),
      .next_pc_predictor_lookup_response_epoch_i(next_pc_predictor_lookup_response_epoch),
      .next_pc_predictor_prediction_i(next_pc_predictor_prediction),
      .next_pc_predictor_lookup_response_valid_i(next_pc_predictor_lookup_response_valid),
      .next_pc_predictor_lookup_response_ready_o(next_pc_predictor_lookup_response_ready),
      .next_pc_predictor_flush_o(next_pc_predictor_flush),
      .icache_lookup_req_o(icache_lookup_req),
      .icache_lookup_req_valid_o(icache_lookup_req_valid),
      .icache_lookup_req_ready_i(icache_lookup_req_ready && frontend_memory_access_allowed),
      .icache_lookup_resp_i(icache_lookup_resp),
      .icache_lookup_resp_valid_i(icache_lookup_resp_valid),
      .icache_lookup_resp_ready_o(icache_lookup_resp_ready),
      .fetch_entry_o(ifu_fetch_entry),
      .fetch_entry_valid_o(ifu_fetch_entry_valid),
      .fetch_entry_ready_i(ifu_fetch_entry_ready)
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

  riscv_icache u_icache (
      .clk_i              (clk_i),
      .rst_ni             (rst_ni),
      .lookup_req_i       (icache_lookup_req),
      .lookup_req_valid_i (icache_lookup_req_valid && frontend_memory_access_allowed),
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

  fetch_entry_t idu_fetch_entry;
  logic         idu_fetch_entry_valid;
  logic         idu_fetch_entry_ready;
  logic         frontend_recovery_event;

  riscv_fetch_buffer u_fetch_buffer (
      .clk_i                  (clk_i),
      .rst_ni                 (rst_ni),
      .ifu_fetch_entry_i      (ifu_fetch_entry),
      .ifu_fetch_entry_valid_i(ifu_fetch_entry_valid),
      .ifu_fetch_entry_ready_o(ifu_fetch_entry_ready),
      .idu_fetch_entry_o      (idu_fetch_entry),
      .idu_fetch_entry_valid_o(idu_fetch_entry_valid),
      .idu_fetch_entry_ready_i(idu_fetch_entry_ready),
      .flush_i                (frontend_recovery_event)
  );

  // 预测器在I-cache之前运行。预测响应与下一次预测请求可以同拍握手；IFU用frontend
  // 请求上下文保存唯一在途取指的预测元数据；队列 ready 传递容量，响应寄存器切断 next-PC 反馈。
  program_counter_t resolved_control_flow_target;
  execute_result_t  resolved_execute_result;

  assign resolved_control_flow_target =
      (resolved_execute_result.uop.branch_ctrl.op == CF_JALR) ?
      resolved_execute_result.next_pc :
      resolved_execute_result.uop.pc +
      program_counter_t'(resolved_execute_result.uop.imm);

  logic resolved_execute_result_valid;
  logic resolved_execute_result_ready;

  riscv_branch_predictor u_branch_predictor (
      .clk_i(clk_i),
      .rst_ni(rst_ni),
      .lookup_request_pc_i(next_pc_predictor_lookup_request_pc),
      .lookup_request_epoch_i(next_pc_predictor_lookup_request_epoch),
      .lookup_request_valid_i(next_pc_predictor_lookup_request_valid),
      .lookup_request_ready_o(next_pc_predictor_lookup_request_ready),
      .lookup_response_pc_o(next_pc_predictor_lookup_response_pc),
      .lookup_response_epoch_o(next_pc_predictor_lookup_response_epoch),
      .lookup_prediction_o(next_pc_predictor_prediction),
      .lookup_next_pc_o(),
      .lookup_response_valid_o(next_pc_predictor_lookup_response_valid),
      .lookup_response_ready_i(next_pc_predictor_lookup_response_ready),
      .resolved_control_flow_pc_i(resolved_execute_result.uop.pc),
      .resolved_control_flow_target_i(resolved_control_flow_target),
      .resolved_control_flow_imm_i(resolved_execute_result.uop.imm),
      .resolved_control_flow_op_i(resolved_execute_result.uop.branch_ctrl.op),
      .resolved_control_flow_rs1_i(resolved_execute_result.uop.rs1),
      .resolved_control_flow_rd_i(resolved_execute_result.uop.rd),
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
      .flush_lookup_i(next_pc_predictor_flush),
      .invalidate_i(icache_invalidate_req)
  );

  // 统计真正随fetch entry进入队列的taken预测，不统计尚未完成I-cache响应配对的请求。
  logic fetch_taken_prediction_event;

  assign fetch_taken_prediction_event =
      ifu_fetch_entry_valid && ifu_fetch_entry_ready &&
      ifu_fetch_entry.prediction.predicted_taken;

  riscv_icache_axi u_icache_axi (
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

  decoded_uop_t decoded_uop;
  logic         decoded_uop_valid;
  logic         decoded_uop_ready;

  riscv_idu u_idu (
      // IDU反压先由fetch queue吸收；队列填满后才会向IFU和I-cache传播。
      .fetch_entry_i      (idu_fetch_entry),
      .fetch_entry_valid_i(idu_fetch_entry_valid),
      .fetch_entry_ready_o(idu_fetch_entry_ready),
      .decoded_uop_o      (decoded_uop),
      .decoded_uop_valid_o(decoded_uop_valid),
      .decoded_uop_ready_i(decoded_uop_ready)
  );

  xlen_data_t    rs1_value;
  xlen_data_t    rs2_value;
  xlen_data_t    gpr_write_data;
  arch_reg_idx_t gpr_write_addr;
  logic          gpr_write_enable;

  riscv_regfile u_arch_regfile (
      .clk_i             (clk_i),
      .gpr_write_data_i  (gpr_write_data),
      .gpr_write_addr_i  (gpr_write_addr),
      .gpr_write_enable_i(gpr_write_enable),
      .rs1_addr_i        (decoded_uop.rs1),
      .rs1_data_o        (rs1_value),
      .rs2_addr_i        (decoded_uop.rs2),
      .rs2_data_o        (rs2_value)
  );

  commit_t          commit;
  logic             commit_valid;
  xlen_data_t       csr_read_data;
  logic             csr_read_illegal;
  program_counter_t csr_mtvec;
  program_counter_t csr_mepc;
  logic             retired_instruction_event;
  logic             trap_valid;
  program_counter_t trap_pc;
  xlen_data_t       trap_cause;
  xlen_data_t       trap_tval;
  logic             mret_valid;

  riscv_csr_file u_csr_file (
      .clk_i                      (clk_i),
      .rst_ni                     (rst_ni),
      .csr_read_enable_i          (decoded_uop_valid && decoded_uop.csr_ctrl.read_enable),
      // CSR地址是固定指令字段，可与opcode译码并行选择；使能仍由合法译码产生。
      .csr_read_addr_i            (idu_fetch_entry.instruction[31:20]),
      .csr_access_write_enable_i  (decoded_uop_valid && decoded_uop.csr_ctrl.write_enable),
      .csr_read_data_o            (csr_read_data),
      .csr_read_illegal_o         (csr_read_illegal),
      .csr_write_valid_i          (commit_valid && commit.csr_write),
      .csr_write_addr_i           (commit.csr_addr),
      .csr_write_data_i           (commit.csr_wdata),
      .retired_instruction_event_i(retired_instruction_event),
      .trap_valid_i               (trap_valid),
      .trap_pc_i                  (trap_pc),
      .trap_cause_i               (trap_cause),
      .trap_tval_i                (trap_tval),
      .mret_valid_i               (mret_valid),
      .mtvec_o                    (csr_mtvec),
      .mepc_o                     (csr_mepc)
  );

  // Issue 检查依赖并读取操作数；ID/EX 是现有的执行输入寄存边界。
  writeback_result_t writeback_result;
  logic writeback_result_valid;
  logic writeback_result_ready;
  execute_packet_t execute_packet;
  logic execute_packet_valid;
  execute_packet_t decoded_execute_packet;
  execute_result_t exu_result;
  writeback_result_t lsu_writeback;
  logic lsu_writeback_valid;
  logic lsu_writeback_ready;
  logic lsu_transaction_active;
  logic decode_accept_allowed;
  logic execute_issue_allowed;
  logic decode_execute_flush;
  logic raw_hazard_present;
  logic serializing_hazard_present;
  logic structural_hazard_present;
  logic commit_redirect_event;
  logic decoded_execute_packet_ready;
  logic execute_packet_ready;
  logic execute_handshake;
  logic scoreboard_allocate_ready;
  scoreboard_index_t scoreboard_allocate_index;
  logic scoreboard_empty;
  logic scoreboard_memory_issue_allowed;
  logic scoreboard_serializing_present;
  logic scoreboard_rs1_pending;
  logic scoreboard_rs1_ready;
  logic scoreboard_rs2_pending;
  logic scoreboard_rs2_ready;
  xlen_data_t scoreboard_rs1_value;
  xlen_data_t scoreboard_rs2_value;
  xlen_data_t issue_rs1_value;
  xlen_data_t issue_rs2_value;
  arithmetic_result_t multiply_result;
  arithmetic_result_t divide_result;
  logic multiply_result_valid;
  logic divide_result_valid;
  logic multiply_result_present;
  logic divide_result_present;
  logic execute_operands_ready;
  xlen_data_t arithmetic_operand[2];
  logic [1:0] issue_operand_pending;
  scoreboard_index_t issue_operand_index[2];
  completion_source_e issue_operand_source[2];
  completion_source_e scoreboard_rs1_source, scoreboard_rs2_source;
  scoreboard_index_t scoreboard_rs1_index, scoreboard_rs2_index;
  arithmetic_result_t operand_completion[3];
  logic [2:0] operand_completion_valid;
  arithmetic_result_t lsu_forward_result;
  logic lsu_forward_valid;
  assign operand_completion[0] = lsu_forward_result;
  assign operand_completion[1] = multiply_result;
  assign operand_completion[2] = divide_result;
  // 数据选择只看已保存结果；恢复仍单独阻止发射并清除等待槽。
  assign operand_completion_valid = {
    divide_result_present, multiply_result_present, lsu_forward_valid
  };

  riscv_issue_ctrl u_issue_ctrl (
      .decoded_uop_i                    (decoded_uop),
      .decoded_uop_valid_i              (decoded_uop_valid),
      .register_rs1_i                   (rs1_value),
      .register_rs2_i                   (rs2_value),
      .execute_packet_i                 (execute_packet),
      .execute_packet_valid_i           (execute_packet_valid),
      .execute_result_i                 (exu_result),
      .scoreboard_rs1_pending_i         (scoreboard_rs1_pending),
      .scoreboard_rs1_ready_i           (scoreboard_rs1_ready),
      .scoreboard_rs1_value_i           (scoreboard_rs1_value),
      .scoreboard_rs2_pending_i         (scoreboard_rs2_pending),
      .scoreboard_rs2_ready_i           (scoreboard_rs2_ready),
      .scoreboard_rs2_value_i           (scoreboard_rs2_value),
      .scoreboard_serializing_present_i (scoreboard_serializing_present),
      .scoreboard_empty_i               (scoreboard_empty),
      .scoreboard_allocate_ready_i      (scoreboard_allocate_ready),
      .scoreboard_memory_issue_allowed_i(scoreboard_memory_issue_allowed),
      .recovery_i                       (older_redirect_event),
      .execute_operands_ready_i         (execute_operands_ready),
      .allocate_index_i                 (scoreboard_allocate_index),
      .scoreboard_rs1_source_i          (scoreboard_rs1_source),
      .scoreboard_rs2_source_i          (scoreboard_rs2_source),
      .operand_source_o                 (issue_operand_source),
      .scoreboard_rs1_index_i           (scoreboard_rs1_index),
      .scoreboard_rs2_index_i           (scoreboard_rs2_index),
      .operand_pending_o                (issue_operand_pending),
      .operand_index_o                  (issue_operand_index),
      .rs1_value_o                      (issue_rs1_value),
      .rs2_value_o                      (issue_rs2_value),
      .decode_accept_allowed_o          (decode_accept_allowed),
      .execute_issue_allowed_o          (execute_issue_allowed),
      .raw_hazard_present_o             (raw_hazard_present),
      .serializing_hazard_present_o     (serializing_hazard_present),
      .structural_hazard_present_o      (structural_hazard_present)
  );

  riscv_operand_mux u_operand_mux (
      .decoded_uop_i           (decoded_uop),
      .rs1_value_i             (issue_rs1_value),
      .rs2_value_i             (issue_rs2_value),
      .csr_read_data_i         (csr_read_data),
      .csr_read_illegal_i      (csr_read_illegal),
      .decoded_execute_packet_o(decoded_execute_packet)
  );

  assign decoded_uop_ready = decoded_execute_packet_ready && decode_accept_allowed;
  assign execute_handshake = execute_packet_valid && execute_issue_allowed && execute_packet_ready;
  assign decode_execute_flush = older_redirect_event;
  riscv_id_ex_reg u_id_ex_reg (
      .operand_pending_i(issue_operand_pending),
      .operand_index_i(issue_operand_index),
      .operand_source_i(issue_operand_source),
      .completion_i(operand_completion),
      .completion_valid_i(operand_completion_valid),
      .operands_ready_o(execute_operands_ready),
      .arithmetic_operand_o(arithmetic_operand),
      .clk_i(clk_i),
      .rst_ni(rst_ni),
      .decoded_execute_packet_i(decoded_execute_packet),
      .decoded_execute_packet_valid_i(decoded_uop_valid && decode_accept_allowed),
      .decoded_execute_packet_ready_o(decoded_execute_packet_ready),
      .execute_packet_o(execute_packet),
      .execute_packet_valid_o(execute_packet_valid),
      .execute_packet_ready_i(execute_packet_ready && execute_issue_allowed),
      .execute_forwardable_producer_present_o(),
      .execute_blocking_producer_present_o(),
      .execute_serializing_instruction_present_o(),
      // 非分支自行纠错保留尚未发射的当前项，发射同拍只取消年轻输入。
      .flush_i(decode_execute_flush || (sequential_redirect_valid && execute_handshake))
  );

  logic     exu_result_valid;
  logic     exu_result_ready;
  lsu_req_t lsu_req;
  logic     lsu_req_valid;
  logic     lsu_req_ready;

  riscv_exu u_exu (
      .arithmetic_operand_i          (arithmetic_operand),
      .clk_i                         (clk_i),
      .rst_ni                        (rst_ni),
      .flush_i                       (commit_redirect_event),
      .issue_flush_i                 (decode_execute_flush),
      .scoreboard_index_i            (scoreboard_allocate_index),
      .multiply_result_o             (multiply_result),
      .multiply_result_valid_o       (multiply_result_valid),
      .multiply_result_present_o     (multiply_result_present),
      .multiply_result_ready_i       (1'b1),
      .divide_result_o               (divide_result),
      .divide_result_valid_o         (divide_result_valid),
      .divide_result_present_o       (divide_result_present),
      .divide_result_ready_i         (1'b1),
      .execute_packet_i              (execute_packet),
      .execute_packet_valid_i        (execute_packet_valid),
      .execute_packet_issue_allowed_i(execute_issue_allowed),
      .execute_packet_ready_o        (execute_packet_ready),
      .exu_result_o                  (exu_result),
      .exu_result_valid_o            (exu_result_valid),
      .exu_result_ready_i            (exu_result_ready),
      .lsu_req_o                     (lsu_req),
      .lsu_req_valid_o               (lsu_req_valid),
      .lsu_req_ready_i               (lsu_req_ready),
      .sequential_redirect_o         (sequential_redirect),
      .sequential_redirect_valid_o   (sequential_redirect_valid)
  );

  // 普通结果在发射沿直接写入 scoreboard。此寄存边界只供预测校验与执行观测读取，
  // 不再把正常结果送回 scoreboard 重复保存；不使用的宽字段由综合删除。
  logic execute_redirect_resolution_event;

  riscv_ex_result_reg u_ex_result_reg (
      .clk_i                  (clk_i),
      .rst_ni                 (rst_ni),
      .executed_result_i      (exu_result),
      .executed_result_valid_i(exu_result_valid),
      .executed_result_ready_o(exu_result_ready),
      .resolved_result_o      (resolved_execute_result),
      .resolved_result_valid_o(resolved_execute_result_valid),
      .resolved_result_ready_i(resolved_execute_result_ready),
      // 分支恢复当拍阻止年轻发射，并清除本级已消费结果的 valid。
      // 提交恢复取消普通结果；FENCE.I 依靠串行化排空后端。
      .flush_i                (execute_redirect_resolution_event || commit_redirect_event)
  );

  data_memory_req_t  data_memory_req;
  logic              data_memory_req_valid;
  logic              data_memory_req_ready;
  data_memory_resp_t data_memory_resp;
  logic              data_memory_resp_valid;
  logic              data_memory_resp_ready;

  riscv_lsu u_lsu (
      .forward_result_o        (lsu_forward_result),
      .forward_valid_o         (lsu_forward_valid),
      .clk_i                   (clk_i),
      .rst_ni                  (rst_ni),
      .lsu_req_i               (lsu_req),
      .lsu_req_valid_i         (lsu_req_valid),
      .lsu_req_ready_o         (lsu_req_ready),
      .lsu_transaction_active_o(lsu_transaction_active),
      .lsu_pending_writes_rd_o (),
      .lsu_pending_rd_o        (),
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

  dcache_event_t dcache_event;
  logic          dcache_clean_req;
  logic          dcache_clean_done;
  logic          dcache_clean_access_fault;
  logic          dcache_busy;

  riscv_data_mem u_data_mem (
      .clk_i                      (clk_i),
      .rst_ni                     (rst_ni),
      .data_memory_req_i          (data_memory_req),
      .data_memory_req_valid_i    (data_memory_req_valid),
      .data_memory_req_ready_o    (data_memory_req_ready),
      .data_memory_resp_o         (data_memory_resp),
      .data_memory_resp_valid_o   (data_memory_resp_valid),
      .data_memory_resp_ready_i   (data_memory_resp_ready),
      .dcache_clean_req_i         (dcache_clean_req),
      .dcache_clean_done_o        (dcache_clean_done),
      .dcache_clean_access_fault_o(dcache_clean_access_fault),
      .dcache_busy_o              (dcache_busy),
      .dcache_event_o             (dcache_event),
      .axi_manager_o              (data_axi4_manager_o),
      .axi_manager_i              (data_axi4_manager_i)
  );

  // 每条已发射指令已经占有结果槽，完成入口无需争用单一 WB 写口。
  assign resolved_execute_result_ready = 1'b1;
  assign lsu_writeback_ready           = 1'b1;
  riscv_scoreboard u_scoreboard (
      .clk_i                  (clk_i),
      .rst_ni                 (rst_ni),
      .flush_i                (commit_redirect_event),
      .allocate_result_i      (exu_result),
      .allocate_completed_i   (exu_result_valid && exu_result_ready),
      .allocate_valid_i       (execute_handshake),
      .allocate_ready_o       (scoreboard_allocate_ready),
      .allocate_index_o       (scoreboard_allocate_index),
      .lsu_result_i           (lsu_writeback),
      .lsu_result_valid_i     (lsu_writeback_valid),
      .multiply_result_i      (multiply_result),
      .multiply_result_valid_i(multiply_result_valid),
      .divide_result_i        (divide_result),
      .divide_result_valid_i  (divide_result_valid),
      .query_uop_i            (decoded_uop),
      .rs1_source_o           (scoreboard_rs1_source),
      .rs2_source_o           (scoreboard_rs2_source),
      .rs1_index_o            (scoreboard_rs1_index),
      .rs2_index_o            (scoreboard_rs2_index),
      .rs1_pending_o          (scoreboard_rs1_pending),
      .rs1_ready_o            (scoreboard_rs1_ready),
      .rs1_value_o            (scoreboard_rs1_value),
      .rs2_pending_o          (scoreboard_rs2_pending),
      .rs2_ready_o            (scoreboard_rs2_ready),
      .rs2_value_o            (scoreboard_rs2_value),
      .serializing_present_o  (scoreboard_serializing_present),
      .empty_o                (scoreboard_empty),
      .memory_issue_allowed_o (scoreboard_memory_issue_allowed),
      .commit_result_o        (writeback_result),
      .commit_result_valid_o  (writeback_result_valid),
      .commit_result_ready_i  (writeback_result_ready)
  );

  riscv_commit u_commit (
      .writeback_result_i      (writeback_result),
      .writeback_result_valid_i(writeback_result_valid),
      .writeback_result_ready_o(writeback_result_ready),
      .commit_o                (commit),
      .commit_valid_o          (commit_valid),
      .gpr_write_data_o        (gpr_write_data),
      .gpr_write_addr_o        (gpr_write_addr),
      .gpr_write_enable_o      (gpr_write_enable)
  );

  // 发生同步异常的指令到达提交边界，但不计入退休指令数。
  assign retired_instruction_event = commit_valid && !commit.trap_taken;

  // 提交后的缓存维护与前端恢复。
  logic          fence_i_maintenance_active;
  logic          committed_fence_i_event;
  redirect_req_t fence_i_redirect_req;

  riscv_fence_i_ctrl u_fence_i_ctrl (
      .clk_i                           (clk_i),
      .rst_ni                          (rst_ni),
      .commit_valid_i                  (commit_valid),
      .commit_i                        (commit),
      .icache_lookup_req_valid_i       (icache_lookup_req_valid),
      .icache_lookup_req_ready_i       (icache_lookup_req_ready),
      .icache_busy_i                   (icache_busy),
      .dcache_clean_done_i             (dcache_clean_done),
      .dcache_clean_access_fault_i     (dcache_clean_access_fault),
      .icache_invalidate_done_i        (icache_invalidate_done),
      .committed_fence_i_event_o       (committed_fence_i_event),
      .fence_i_redirect_req_o          (fence_i_redirect_req),
      .fence_i_maintenance_active_o    (fence_i_maintenance_active),
      .frontend_memory_access_allowed_o(frontend_memory_access_allowed),
      .frontend_prediction_allowed_o   (frontend_prediction_allowed),
      .dcache_clean_req_o              (dcache_clean_req),
      .icache_invalidate_req_o         (icache_invalidate_req)
  );

  redirect_req_t commit_redirect_req_at_resolution;
  logic          commit_redirect_resolution_event;

  riscv_trap_ctrl u_trap_ctrl (
      .commit_i            (commit),
      .commit_valid_i      (commit_valid),
      .mtvec_i             (csr_mtvec),
      .mepc_i              (csr_mepc),
      .trap_valid_o        (trap_valid),
      .trap_pc_o           (trap_pc),
      .trap_cause_o        (trap_cause),
      .trap_tval_o         (trap_tval),
      .mret_valid_o        (mret_valid),
      .redirect_req_o      (commit_redirect_req_at_resolution),
      .redirect_req_valid_o(commit_redirect_resolution_event)
  );

  redirect_req_t execute_redirect_req_at_resolution;

  assign execute_redirect_req_at_resolution = resolved_execute_result.redirect_req;
  assign execute_redirect_resolution_event  =
      resolved_execute_result_valid && resolved_execute_result_ready &&
      resolved_execute_result.redirect_valid;

  // 提交恢复优先于 FENCE.I，再优先于分支修正；同拍直接送达前端与 flush。
  redirect_req_t redirect_req_at_resolution_array[REDIRECT_SOURCE_COUNT];
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

  riscv_redirect_mux #(
      .SOURCE_COUNT(REDIRECT_SOURCE_COUNT)
  ) u_redirect_mux (
      .redirect_req_i      (redirect_req_at_resolution_array),
      .redirect_req_valid_i(redirect_req_at_resolution_valid_vector),
      .redirect_req_o      (selected_redirect_req),
      .redirect_req_valid_o(selected_redirect_req_valid)
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

  // lookup request/response属于IFU与I-cache边界；delivery和waiting属于IFU与IDU边界。
  // 分开统计才能区分cache等待与译码反压。
  logic [SCOREBOARD_ENTRY_COUNT-1:0] sim_completion_event_vector;
  for (
      genvar entry_index = 0; entry_index < SCOREBOARD_ENTRY_COUNT; entry_index++
  ) begin : gen_sim_completion
    assign sim_completion_event_vector[entry_index] =
        (resolved_execute_result_valid && resolved_execute_result.scoreboard_index == scoreboard_index_t'(entry_index)) ||
        (lsu_writeback_valid && lsu_writeback.scoreboard_index == scoreboard_index_t'(entry_index)) ||
        (multiply_result_valid && multiply_result.scoreboard_index == scoreboard_index_t'(entry_index)) ||
        (divide_result_valid && divide_result.scoreboard_index == scoreboard_index_t'(entry_index));
  end

  riscv_sim_perf_monitor u_sim_perf_monitor (
      .clk_i(clk_i),
      .rst_ni(rst_ni),
      .ifu_instruction_request_event_i (
          icache_lookup_req_valid && icache_lookup_req_ready && frontend_memory_access_allowed
      ),
      .ifu_instruction_request_waiting_i(
          icache_lookup_req_valid &&
          (!icache_lookup_req_ready || !frontend_memory_access_allowed)
      ),
      .ifu_instruction_response_event_i(icache_lookup_resp_valid && icache_lookup_resp_ready),
      .ifu_instruction_response_discarded_event_i (
          icache_lookup_resp_valid && icache_lookup_resp_ready && !ifu_fetch_entry_valid
      ),
      .ifu_instruction_delivery_event_i(idu_fetch_entry_valid && idu_fetch_entry_ready),
      .ifu_downstream_waiting_i(idu_fetch_entry_valid && !idu_fetch_entry_ready),
      .icache_miss_event_i(icache_event.miss_event),
      .instruction_decode_event_i(decoded_uop_valid && decoded_uop_ready),
      .decoded_fu_type_i(decoded_uop.fu_type),
      .decoded_memory_cmd_i(decoded_uop.mem_ctrl.cmd),
      .exu_completion_count_i          (2'(resolved_execute_result_valid) + 2'(multiply_result_valid) + 2'(divide_result_valid)),
      .lsu_completion_event_i(lsu_writeback_valid && lsu_writeback_ready),
      .instruction_retirement_event_i(retired_instruction_event),
      .instruction_issue_event_i(execute_handshake),
      .instruction_issue_index_i(scoreboard_allocate_index),
      .instruction_issue_fu_type_i(execute_packet.uop.fu_type),
      .completion_event_vector_i(sim_completion_event_vector),
      .backend_flush_i(commit_redirect_event),
      .pipeline_raw_hazard_waiting_i(raw_hazard_present),
      .pipeline_serializing_waiting_i(serializing_hazard_present),
      .pipeline_scoreboard_waiting_i(!scoreboard_allocate_ready),
      .pipeline_memory_order_waiting_i (execute_packet_valid &&
          execute_packet.uop.fu_type == FU_LSU && !scoreboard_memory_issue_allowed),
      .pipeline_lsu_waiting_i          (execute_packet_valid &&
          execute_packet.uop.fu_type == FU_LSU && !execute_packet_ready),
      .pipeline_structural_waiting_i((structural_hazard_present ||
          (execute_packet_valid && !execute_packet_ready)) && decoded_uop_valid),
      .frontend_supply_waiting_i      (
          !decoded_uop_valid && !structural_hazard_present &&
          !commit_redirect_event
      ),
      .pipeline_control_flush_event_i(frontend_recovery_event),
      .pipeline_execute_instruction_discarded_i(commit_redirect_event && execute_packet_valid),
      .fetch_taken_prediction_event_i(fetch_taken_prediction_event),
      // 纠错事件和控制流字段必须来自同一条 EX 结果，
      // 不能与当前 EXU 中下一条指令的字段配对。
      .execute_misprediction_redirect_event_i(execute_redirect_resolution_event),
      .control_flow_resolution_event_i        (
          resolved_execute_result_valid && resolved_execute_result_ready &&
          (resolved_execute_result.uop.fu_type == FU_BRANCH) &&
          !resolved_execute_result.uop.exception_valid
      ),
      .resolved_control_flow_op_i(resolved_execute_result.uop.branch_ctrl.op),
      .resolved_control_flow_pc_i(resolved_execute_result.uop.pc),
      .resolved_control_flow_taken_i(
          (resolved_execute_result.uop.branch_ctrl.op != CF_BRANCH) ||
          (resolved_execute_result.next_pc !=
          (resolved_execute_result.uop.pc + program_counter_t'(INSTRUCTION_BYTES)))
      ),
      .resolved_control_flow_immediate_i(resolved_execute_result.uop.imm),
      .lsu_request_event_i(lsu_req_valid && lsu_req_ready),
      .lsu_request_memory_cmd_i(lsu_req.uop.mem_ctrl.cmd),
      .lsu_read_address_event_i(data_axi4_manager_o.ar_valid && data_axi4_manager_i.ar_ready),
      .lsu_read_response_event_i(data_axi4_manager_i.r_valid && data_axi4_manager_o.r_ready),
      .lsu_write_address_event_i(data_axi4_manager_o.aw_valid && data_axi4_manager_i.aw_ready),
      .lsu_write_data_event_i(data_axi4_manager_o.w_valid && data_axi4_manager_i.w_ready),
      .lsu_write_response_event_i(data_axi4_manager_i.b_valid && data_axi4_manager_o.b_ready),
      .icache_cacheable_hit_count_i(sim_icache_cacheable_hit_count),
      .icache_cacheable_miss_response_count_i(sim_icache_cacheable_miss_response_count),
      .icache_hit_latency_cycle_sum_i(sim_icache_hit_latency_cycle_sum),
      .icache_miss_response_latency_cycle_sum_i(sim_icache_miss_response_latency_cycle_sum)
  );

  // Cache性能统计只存在于仿真配置。它观察I-cache定义的语义事件，不从AXI
  // beat反推hit/miss，因此不会把一次cache line refill误计成多次miss。
  riscv_sim_icache_monitor u_sim_icache_monitor (
      .clk_i                            (clk_i),
      .rst_ni                           (rst_ni),
      .icache_event_i                   (icache_event),
      .cacheable_hit_count_o            (sim_icache_cacheable_hit_count),
      .cacheable_miss_response_count_o  (sim_icache_cacheable_miss_response_count),
      .hit_latency_cycle_sum_o          (sim_icache_hit_latency_cycle_sum),
      .miss_response_latency_cycle_sum_o(sim_icache_miss_response_latency_cycle_sum)
  );

  // D-cache监视器直接消费cache语义事件，不根据AXI beat反推hit/miss。这样一条
  // cache-line refill仍然只对应一次需求miss，并可独立观察脏替换写回成本。
  riscv_sim_dcache_monitor u_sim_dcache_monitor (
      .clk_i         (clk_i),
      .rst_ni        (rst_ni),
      .dcache_event_i(dcache_event)
  );
`endif

`ifndef SYNTHESIS
  // rst_ni是状态寄存器的异步复位，同时也是SVA的disable条件。Verilator会把后者
  // 视为同步使用并报告SYNCASYNCNET；该诊断不代表复位网络存在功能冲突。
  /* verilator lint_off SYNCASYNCNET */
  // fence.i维护请求按D-cache clean、I-cache invalidate的固定顺序保持到完成。
  a_dcache_clean_request_held_until_done :
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (dcache_clean_req && !dcache_clean_done) |=> dcache_clean_req)
  else $error("core withdrew D-cache clean request before completion");

  a_icache_invalidate_request_held_until_done :
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (icache_invalidate_req && !icache_invalidate_done) |=> icache_invalidate_req)
  else $error("core withdrew I-cache invalidate request before completion");

  a_icache_invalidate_done_has_request :
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    icache_invalidate_done |-> icache_invalidate_req)
  else $error("core observed I-cache invalidate completion without a request");

  a_icache_invalidate_request_means_busy :
  assert property (@(posedge clk_i) disable iff (!rst_ni) icache_invalidate_req |-> icache_busy)
  else $error("I-cache dropped busy while an invalidate transaction was pending");

  a_dcache_clean_request_means_busy :
  assert property (@(posedge clk_i) disable iff (!rst_ni) dcache_clean_req |-> dcache_busy)
  else $error("D-cache dropped busy while a clean transaction was pending");

  a_failed_clean_keeps_frontend_blocked :
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (dcache_clean_req && dcache_clean_done && dcache_clean_access_fault) |=>
      (fence_i_maintenance_active && !icache_invalidate_req &&
       !next_pc_predictor_lookup_request_valid))
  else $error("FENCE.I resumed after a failed D-cache clean");

  // FENCE.I依靠serializing语义排空后端，而不是在提交拍用组合flush补救。该性质成立时，
  // committed_fence_i_event 同拍发起重定向，并启动 cache 维护事务。
  a_committed_fence_i_has_no_younger_backend_work :
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    committed_fence_i_event |->
    (!execute_packet_valid && !lsu_transaction_active &&
     (!resolved_execute_result_valid ||
      (resolved_execute_result.uop.pc == commit.pc &&
       resolved_execute_result.uop.system_op == SYS_FENCE_I))))
  else $error("FENCE.I committed while younger backend work was still present");

  // 老异常在 EX 结果级时就阻止年轻 LSU 请求，不能等到 WB 恢复再取消已接收的访存。
  a_execute_exception_blocks_younger_memory :
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (resolved_execute_result_valid && resolved_execute_result.uop.exception_valid) |->
      (!lsu_req_valid))
  else $error("older EX result exception allowed a younger memory request");

  // 精确异常在 commit 成为架构事件，此时也不能残留此前接收的年轻 LSU 事务。
  a_committed_exception_flushes_younger_instructions :
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (commit_valid && commit.trap_taken) |->
    (commit_redirect_event && decode_execute_flush &&
     !execute_issue_allowed && !lsu_transaction_active))
  else $error("committed exception did not block and flush younger pipeline work");

  // LSU 只能越过已排除异常的纯运算；前一条访存必须提交后才释放上下文。
  a_memory_issue_is_irrevocable :
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (lsu_req_valid && lsu_req_ready) |->
      (scoreboard_memory_issue_allowed && !older_redirect_event))
  else $error("Memory request bypassed exception or side-effect ordering");

  a_resolved_execute_redirect_blocks_younger_execute :
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (resolved_execute_result_valid && resolved_execute_result.redirect_valid) |->
      (decode_execute_flush && !execute_issue_allowed && !lsu_req_valid))
  else $error("resolved execute redirect allowed a wrong-path EX side effect");

  /* verilator lint_on SYNCASYNCNET */
`endif

endmodule
