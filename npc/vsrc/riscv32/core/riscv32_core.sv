// Synthesizable processor core. Simulation memory, DPI, and shared-system
// arbitration are intentionally outside this module.
module riscv32_core
  import riscv_config_pkg::*;
  import riscv32_pkg::*;
  import riscv32_axi4_pkg::*;
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
  dcache_event_t dcache_event;
`ifdef NPC_ENABLE_SIM_MONITOR
  logic [63:0] sim_icache_cacheable_hit_count;
  logic [63:0] sim_icache_cacheable_miss_response_count;
  logic [63:0] sim_icache_hit_latency_cycle_sum;
  logic [63:0] sim_icache_miss_response_latency_cycle_sum;
`endif
  logic icache_invalidate_req;
  logic icache_invalidate_done;
  logic icache_busy;
  logic dcache_clean_req;
  logic dcache_clean_done;
  logic dcache_clean_access_fault;
  logic dcache_busy;
  logic fence_i_maintenance_active;
  logic frontend_memory_access_allowed;

  typedef enum logic [1:0] {
    FENCE_I_MAINTENANCE_IDLE,
    FENCE_I_CLEAN_DCACHE,
    FENCE_I_INVALIDATE_ICACHE
  } fence_i_maintenance_state_e;

  fence_i_maintenance_state_e fence_i_maintenance_state_q;
  fence_i_maintenance_state_e fence_i_maintenance_state_d;

  // IFU维持一个I-cache lookup在途；两项fetch queue保存已完成响应并吸收短暂后端反压。
  // 队列不是分支预测器，也不能掩盖无限停顿；其作用是让命中I-cache在后端短暂停顿时
  // 继续逐拍预取，并把I-cache响应路径与IDU冒险判断隔开。
  fetch_entry_t ifu_fetch_entry;
  logic ifu_fetch_entry_valid;
  logic ifu_fetch_entry_ready;
  branch_prediction_t next_pc_predictor_prediction;
  logic next_pc_predictor_request_ready;
  logic next_pc_predictor_response_valid;
  program_counter_t resolved_control_flow_target;
  logic fetch_taken_prediction_occurred;
  fetch_entry_t idu_fetch_entry;
  logic idu_fetch_entry_valid;
  logic idu_fetch_entry_ready;

  decoded_uop_t idu_decoded_uop;
  logic         idu_decoded_uop_valid;
  logic         idu_decoded_uop_ready;
  decoded_uop_t decoded_uop;
  logic         decoded_uop_valid;
  logic         decoded_uop_ready;

  // IDU和寄存器堆组合生成待进入ID/EX的payload；decode_execute_stage输出才是
  // 当前EX级指令。两个名称显式区分流水级边界两侧，避免把组合译码结果误当成寄存状态。
  xlen_data_t rs1_value;
  xlen_data_t rs2_value;
  execute_packet_t decoded_execute_packet;
  logic decoded_execute_packet_valid;
  logic decoded_execute_packet_ready;
  execute_packet_t execute_packet;
  logic execute_packet_valid;
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

  writeback_result_t completion_result;
  logic completion_result_valid;
  logic completion_result_ready;

  writeback_result_t writeback_result;
  logic writeback_result_valid;
  logic writeback_result_ready;

  commit_t commit;
  logic commit_valid;
  logic committed_fence_i_occurred;
  redirect_req_t fence_i_redirect_req;
  redirect_req_t commit_redirect_req_at_resolution;
  logic          commit_redirect_resolution_occurred;

  xlen_data_t gpr_write_data;
  arch_reg_idx_t gpr_write_addr;
  logic gpr_write_enable;

  xlen_data_t csr_read_data;
  logic csr_read_illegal;
  program_counter_t csr_mtvec;
  program_counter_t csr_mepc;
  logic retired_instruction_occurred;

  logic trap_valid;
  program_counter_t trap_pc;
  xlen_data_t trap_cause;
  xlen_data_t trap_tval;
  logic mret_valid;

  redirect_req_t redirect_req[REDIRECT_SOURCE_COUNT];
  logic [REDIRECT_SOURCE_COUNT-1:0] redirect_req_valid;
  redirect_req_t selected_redirect_req;
  logic selected_redirect_req_valid;

  logic decode_accept_allowed;
  logic execute_issue_allowed;
  logic decode_execute_flush;
  logic writeback_flush;
  logic raw_hazard_present;
  logic serializing_hazard_present;
  logic structural_hazard_present;
  logic lsu_transaction_active;
  logic lsu_pending_writes_rd;
  arch_reg_idx_t lsu_pending_rd;
  redirect_req_t execute_redirect_req_at_resolution;
  logic execute_redirect_resolution_occurred;
  logic execute_redirect_occurred;
  logic commit_redirect_occurred;
  logic frontend_recovery_occurred;
  logic execute_forwarding_available;
  logic writeback_forwarding_available;
  logic rs1_execute_forwarding_selected;
  logic rs1_lsu_forwarding_selected;
  logic rs1_writeback_forwarding_selected;
  logic rs2_execute_forwarding_selected;
  logic rs2_lsu_forwarding_selected;
  logic rs2_writeback_forwarding_selected;

  always_comb begin
    decoded_execute_packet             = '0;
    decoded_execute_packet.uop         = decoded_uop;
    decoded_execute_packet.rs1_value   = rs1_value;
    decoded_execute_packet.rs2_value   = rs2_value;
    decoded_execute_packet.csr_rdata   = csr_read_data;
    decoded_execute_packet.csr_illegal = csr_read_illegal;

    // WB生产者可能在本拍提交并离开，因此必须在ID/EX采样前完成同拍写回前递。
    // EX和刚完成的LSU生产者会在同一时钟沿进入WB，年轻指令下一拍在EXU输入前递，
    // 不能把它们的组合结果反向接到这里，否则会形成ALU -> ID/EX的跨级关键路径。
    if (rs1_writeback_forwarding_selected) begin
      decoded_execute_packet.rs1_value = writeback_result.result;
    end
    if (rs2_writeback_forwarding_selected) begin
      decoded_execute_packet.rs2_value = writeback_result.result;
    end
  end

  riscv32_ifu #(
      .PC_START(RESET_PC)
  ) u_ifu (
      .clk_i                     (clk_i),
      .rst_ni                    (rst_ni),
      .redirect_req_i            (selected_redirect_req),
      .redirect_req_valid_i      (selected_redirect_req_valid),
      .next_pc_predictor_prediction_i(next_pc_predictor_prediction),
      .icache_lookup_req_o       (icache_lookup_req),
      .icache_lookup_req_valid_o (icache_lookup_req_valid),
      .icache_lookup_req_ready_i (
          icache_lookup_req_ready && next_pc_predictor_request_ready &&
          frontend_memory_access_allowed
      ),
      .icache_lookup_resp_i      (icache_lookup_resp),
      .icache_lookup_resp_valid_i(
          icache_lookup_resp_valid && next_pc_predictor_response_valid
      ),
      .icache_lookup_resp_ready_o(icache_lookup_resp_ready),
      .fetch_entry_o             (ifu_fetch_entry),
      .fetch_entry_valid_o       (ifu_fetch_entry_valid),
      .fetch_entry_ready_i       (ifu_fetch_entry_ready)
  );

  riscv32_icache u_icache (
      .clk_i              (clk_i),
      .rst_ni             (rst_ni),
      .lookup_req_i       (icache_lookup_req),
      .lookup_req_valid_i (
          icache_lookup_req_valid && next_pc_predictor_request_ready &&
          frontend_memory_access_allowed
      ),
      .lookup_req_ready_o (icache_lookup_req_ready),
      .lookup_resp_o      (icache_lookup_resp),
      .lookup_resp_valid_o(icache_lookup_resp_valid),
      .lookup_resp_ready_i(icache_lookup_resp_ready && next_pc_predictor_response_valid),
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
      .flush_i                (frontend_recovery_occurred)
  );

  // 预测器与I-cache并行接收同一个PC，并通过ready/valid保持一一对应。任一侧无法接收时，
  // 两侧都不能单独握手；返回时也只有预测结果和I-cache数据同时有效才允许IFU消费。
  assign resolved_control_flow_target =
      (exu_result.uop.branch_ctrl.op == CF_JALR) ?
      exu_result.next_pc :
      exu_result.uop.pc + program_counter_t'(exu_result.uop.imm);

  riscv32_fetch_control_flow_predictor u_fetch_control_flow_predictor (
      .clk_i                              (clk_i),
      .rst_ni                             (rst_ni),
      .lookup_request_pc_i                (program_counter_t'(icache_lookup_req.fetch_addr)),
      .lookup_request_valid_i             (
          icache_lookup_req_valid && icache_lookup_req_ready && frontend_memory_access_allowed
      ),
      .lookup_request_ready_o             (next_pc_predictor_request_ready),
      .lookup_prediction_o                (next_pc_predictor_prediction),
      .lookup_next_pc_o                   (),
      .lookup_response_valid_o            (next_pc_predictor_response_valid),
      .lookup_response_ready_i            (
          icache_lookup_resp_ready && icache_lookup_resp_valid
      ),
      .resolved_control_flow_pc_i         (exu_result.uop.pc),
      .resolved_control_flow_target_i     (resolved_control_flow_target),
      .resolved_control_flow_imm_i        (exu_result.uop.imm),
      .resolved_control_flow_op_i         (exu_result.uop.branch_ctrl.op),
      .resolved_control_flow_rs1_i        (exu_result.uop.rs1),
      .resolved_control_flow_rd_i         (exu_result.uop.rd),
      .resolved_control_flow_occurred_i   (
          exu_result_valid && exu_result_ready &&
          (exu_result.uop.fu_type == FU_BRANCH) && !exu_result.uop.exception_valid
      ),
      .resolved_control_flow_taken_i      (
          (exu_result.uop.branch_ctrl.op != CF_BRANCH) ||
          (exu_result.next_pc !=
           (exu_result.uop.pc + program_counter_t'(INSTRUCTION_BYTES)))
      ),
      .invalidate_i                       (icache_invalidate_req)
  );

  // 统计真正随fetch entry进入队列的taken预测，不统计尚未完成I-cache响应配对的请求。
  assign fetch_taken_prediction_occurred =
      ifu_fetch_entry_valid && ifu_fetch_entry_ready &&
      ifu_fetch_entry.prediction.predicted_taken;

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

  // write-back D-cache加入后，fence.i必须先把脏数据写回内存，再失效I-cache。
  // 顺序相反会让I-cache从内存重新取回旧指令。维护期间停止接收新lookup，但允许已经
  // 发出的响应继续排空；未来乱序核应由ROB提交端发起同一维护事务并等待完成。
  assign committed_fence_i_occurred = commit_valid && !commit.trap_taken && (commit.system_op == SYS_FENCE_I);
  assign fence_i_maintenance_active = fence_i_maintenance_state_q != FENCE_I_MAINTENANCE_IDLE;
  // The committed fence event changes the registered maintenance state at the next edge.
  // Requests accepted in the discovery cycle belong to the old epoch and are discarded by
  // the registered frontend redirect. Keeping the raw commit event out of this ready/valid
  // path avoids a commit -> IFU -> I-cache array combinational timing path.
  assign frontend_memory_access_allowed = !fence_i_maintenance_active;
  assign dcache_clean_req = fence_i_maintenance_state_q == FENCE_I_CLEAN_DCACHE;
  assign icache_invalidate_req = fence_i_maintenance_state_q == FENCE_I_INVALIDATE_ICACHE;

  always_comb begin
    fence_i_maintenance_state_d = fence_i_maintenance_state_q;
    unique case (fence_i_maintenance_state_q)
      FENCE_I_MAINTENANCE_IDLE: begin
        if (committed_fence_i_occurred) begin
          // 无D-cache配置直接进入I-cache失效；有D-cache时必须先写回dirty line。
          fence_i_maintenance_state_d = DCACHE_ENABLED ? FENCE_I_CLEAN_DCACHE :
                                                        FENCE_I_INVALIDATE_ICACHE;
        end
      end
      FENCE_I_CLEAN_DCACHE: begin
        if (dcache_clean_done) begin
          fence_i_maintenance_state_d = FENCE_I_INVALIDATE_ICACHE;
        end
      end
      FENCE_I_INVALIDATE_ICACHE: begin
        if (icache_invalidate_done) begin
          fence_i_maintenance_state_d = FENCE_I_MAINTENANCE_IDLE;
        end
      end
      default: fence_i_maintenance_state_d = FENCE_I_MAINTENANCE_IDLE;
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      fence_i_maintenance_state_q <= FENCE_I_MAINTENANCE_IDLE;
    end else begin
      fence_i_maintenance_state_q <= fence_i_maintenance_state_d;
    end
  end

  riscv32_idu u_idu (
      // IDU反压先由fetch queue吸收；队列填满后才会向IFU和I-cache传播。
      .fetch_entry_i      (idu_fetch_entry),
      .fetch_entry_valid_i(idu_fetch_entry_valid),
      .fetch_entry_ready_o(idu_fetch_entry_ready),
      .decoded_uop_o      (idu_decoded_uop),
      .decoded_uop_valid_o(idu_decoded_uop_valid),
      .decoded_uop_ready_i(idu_decoded_uop_ready)
  );

  // 完整译码在这里结束。后续寄存器堆/CSR读取、冒险比较和前递选择从已寄存uop开始，
  // 避免fetch queue读选择与这些逻辑串成一条长路径。该级和ID/EX级都支持滚动握手，
  // 因此新增一级只增加单条指令延迟，不降低无阻塞指令流的稳态吞吐。
  riscv32_decode_stage u_decode_stage (
      .clk_i                  (clk_i),
      .rst_ni                 (rst_ni),
      .idu_decoded_uop_i      (idu_decoded_uop),
      .idu_decoded_uop_valid_i(idu_decoded_uop_valid),
      .idu_decoded_uop_ready_o(idu_decoded_uop_ready),
      .decoded_uop_o          (decoded_uop),
      .decoded_uop_valid_o    (decoded_uop_valid),
      .decoded_uop_ready_i    (decoded_uop_ready),
      .flush_i                (decode_execute_flush)
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
      .csr_access_write_enable_i     (decoded_uop_valid && decoded_uop.csr_ctrl.write_enable),
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

  // 非LSU执行结果在EX组合完成后可直接前递；WB结果在提交当拍也可前递。load结果只有
  // 到达LSU completion/WB后才可用，因此load-use仍由RAW逻辑停顿。串行化指令继续排空后端。
  assign execute_forwarding_available = exu_result_valid && exu_result.uop.writes_rd &&
                                        !exu_result.uop.exception_valid;
  assign writeback_forwarding_available = writeback_result_valid &&
                                          writeback_result.uop.writes_rd &&
                                          !writeback_result.uop.exception_valid;
  riscv32_pipeline_hazard_controller u_pipeline_hazard_controller (
      .clk_i                       (clk_i),
      .rst_ni                      (rst_ni),
      .decoded_uop_valid_i         (decoded_uop_valid),
      .decoded_uses_rs1_i          (decoded_uop.uses_rs1),
      .decoded_rs1_i               (decoded_uop.rs1),
      .decoded_uses_rs2_i          (decoded_uop.uses_rs2),
      .decoded_rs2_i               (decoded_uop.rs2),
      .decoded_serializing_i       (decoded_uop.serializing),
      .execute_uop_valid_i         (execute_packet_valid),
      .execute_writes_rd_i         (execute_packet.uop.writes_rd),
      .execute_rd_i                (execute_packet.uop.rd),
      .execute_serializing_i       (execute_packet.uop.serializing),
      .execute_forwarding_available_i(execute_forwarding_available),
      .writeback_result_valid_i    (writeback_result_valid),
      .writeback_writes_rd_i       (writeback_result.uop.writes_rd),
      .writeback_rd_i              (writeback_result.uop.rd),
      .writeback_serializing_i     (writeback_result.uop.serializing),
      .writeback_forwarding_available_i(writeback_forwarding_available),
      .lsu_busy_i                  (lsu_transaction_active),
      .lsu_pending_writes_rd_i     (lsu_pending_writes_rd),
      .lsu_pending_rd_i            (lsu_pending_rd),
      .lsu_forwarding_available_i  (lsu_writeback_valid && lsu_writeback.uop.writes_rd &&
                                    !lsu_writeback.uop.exception_valid),
      .execute_redirect_occurred_i (execute_redirect_resolution_occurred ||
                                     selected_redirect_req_valid),
      .commit_redirect_occurred_i  (commit_redirect_occurred),
      .decode_accept_allowed_o     (decode_accept_allowed),
      .execute_issue_allowed_o     (execute_issue_allowed),
      .decode_execute_flush_o      (decode_execute_flush),
      .writeback_flush_o           (writeback_flush),
      .raw_hazard_present_o        (raw_hazard_present),
      .serializing_hazard_present_o(serializing_hazard_present),
      .structural_hazard_present_o (structural_hazard_present),
      .rs1_execute_forwarding_selected_o(rs1_execute_forwarding_selected),
      .rs1_lsu_forwarding_selected_o(rs1_lsu_forwarding_selected),
      .rs1_writeback_forwarding_selected_o(rs1_writeback_forwarding_selected),
      .rs2_execute_forwarding_selected_o(rs2_execute_forwarding_selected),
      .rs2_lsu_forwarding_selected_o(rs2_lsu_forwarding_selected),
      .rs2_writeback_forwarding_selected_o(rs2_writeback_forwarding_selected)
  );

  // valid和ready同时受冒险策略约束，保证被停顿的fetch entry仍由IFU/I-cache持有，
  // 不会出现“stage没有保存，但上游认为已经交付”的消息丢失。
  assign decoded_execute_packet_valid = decoded_uop_valid && decode_accept_allowed;
  assign decoded_uop_ready            = decoded_execute_packet_ready && decode_accept_allowed;

  riscv32_decode_execute_stage u_decode_execute_stage (
      .clk_i                         (clk_i),
      .rst_ni                        (rst_ni),
      .decoded_execute_packet_i      (decoded_execute_packet),
      .decoded_execute_packet_valid_i(decoded_execute_packet_valid),
      .decoded_execute_packet_ready_o(decoded_execute_packet_ready),
      .execute_packet_o              (execute_packet),
      .execute_packet_valid_o        (execute_packet_valid),
      .execute_packet_ready_i        (execute_packet_ready && execute_issue_allowed),
      .flush_i                       (decode_execute_flush)
  );

  riscv32_exu u_exu (
      .execute_packet_i      (execute_packet),
      .execute_packet_valid_i(execute_packet_valid && execute_issue_allowed),
      .execute_packet_ready_o(execute_packet_ready),
      .writeback_forwarding_result_i(writeback_result),
      .writeback_forwarding_result_valid_i(writeback_result_valid),
      .exu_result_o          (exu_result),
      .exu_result_valid_o    (exu_result_valid),
      .exu_result_ready_i    (exu_result_ready),
      .lsu_req_o             (lsu_req),
      .lsu_req_valid_o       (lsu_req_valid),
      .lsu_req_ready_i       (lsu_req_ready)
  );

  riscv32_lsu u_lsu (
      .clk_i                   (clk_i),
      .rst_ni                  (rst_ni),
      .lsu_req_i               (lsu_req),
      .lsu_req_valid_i         (lsu_req_valid),
      .lsu_req_ready_o         (lsu_req_ready),
      .lsu_transaction_active_o(lsu_transaction_active),
      .lsu_pending_writes_rd_o (lsu_pending_writes_rd),
      .lsu_pending_rd_o        (lsu_pending_rd),
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

  riscv32_data_memory_subsystem u_data_memory_subsystem (
      .clk_i                       (clk_i),
      .rst_ni                      (rst_ni),
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

  riscv32_completion_mux u_completion_mux (
      .exu_result_i             (exu_result),
      .exu_result_valid_i       (exu_result_valid),
      .exu_result_ready_o       (exu_result_ready),
      .lsu_writeback_i          (lsu_writeback),
      .lsu_writeback_valid_i    (lsu_writeback_valid),
      .lsu_writeback_ready_o    (lsu_writeback_ready),
      .writeback_result_o       (completion_result),
      .writeback_result_valid_o (completion_result_valid),
      .writeback_result_ready_i (completion_result_ready)
  );

  // EXU/LSU completion先进入WB弹性寄存器，再由commit产生唯一架构事件。
  // 这既切断执行到寄存器堆的长组合路径，也让Difftest只观察稳定的退休级payload。
  riscv32_writeback_stage u_writeback_stage (
      .clk_i                    (clk_i),
      .rst_ni                   (rst_ni),
      .completion_result_i      (completion_result),
      .completion_result_valid_i(completion_result_valid),
      .completion_result_ready_o(completion_result_ready),
      .writeback_result_o       (writeback_result),
      .writeback_result_valid_o (writeback_result_valid),
      .writeback_result_ready_i (writeback_result_ready),
      .flush_i                  (writeback_flush)
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
  // lookup request/response属于IFU与I-cache边界；delivery和waiting属于IFU与IDU边界。
  // 分开统计才能区分cache等待与译码反压。
  riscv32_sim_performance_monitor u_sim_performance_monitor (
      .clk_i(clk_i),
      .rst_ni(rst_ni),
      .ifu_instruction_request_occurred_i(
          icache_lookup_req_valid && icache_lookup_req_ready &&
          next_pc_predictor_request_ready && frontend_memory_access_allowed
      ),
      .ifu_instruction_request_waiting_i(
          icache_lookup_req_valid &&
          (!icache_lookup_req_ready || !next_pc_predictor_request_ready ||
           !frontend_memory_access_allowed)
      ),
      .ifu_instruction_response_occurred_i(
          icache_lookup_resp_valid && next_pc_predictor_response_valid &&
          icache_lookup_resp_ready
      ),
      .ifu_instruction_response_discarded_occurred_i(
          icache_lookup_resp_valid && next_pc_predictor_response_valid &&
          icache_lookup_resp_ready && !ifu_fetch_entry_valid
      ),
      .ifu_instruction_delivery_occurred_i(idu_fetch_entry_valid && idu_fetch_entry_ready),
      .ifu_downstream_waiting_i(idu_fetch_entry_valid && !idu_fetch_entry_ready),
      .icache_miss_occurred_i(icache_event.miss_occurred),
      .instruction_decode_occurred_i(idu_decoded_uop_valid && idu_decoded_uop_ready),
      .decoded_fu_type_i(idu_decoded_uop.fu_type),
      .decoded_memory_cmd_i(idu_decoded_uop.mem_ctrl.cmd),
      .exu_completion_occurred_i(exu_result_valid && exu_result_ready),
      .lsu_completion_occurred_i(lsu_writeback_valid && lsu_writeback_ready),
      .instruction_retirement_occurred_i(retired_instruction_occurred),
      .pipeline_raw_hazard_waiting_i(raw_hazard_present),
      .pipeline_serializing_waiting_i(serializing_hazard_present),
      .pipeline_structural_waiting_i(structural_hazard_present && decoded_uop_valid),
      .frontend_supply_waiting_i(!decoded_uop_valid && !structural_hazard_present &&
                                 !commit_redirect_occurred),
      .pipeline_control_flush_occurred_i(frontend_recovery_occurred),
      .pipeline_execute_instruction_discarded_i(commit_redirect_occurred && execute_packet_valid),
      .fetch_taken_prediction_occurred_i(fetch_taken_prediction_occurred),
      // 性能分类必须在EX结果有效的原始拍采样op；registered redirect晚一拍，
      // 若用它与当前exu_result配对，会把纠错归到下一条无关指令。
      .execute_misprediction_redirect_occurred_i(execute_redirect_resolution_occurred),
      .control_flow_resolution_occurred_i(
          exu_result_valid && exu_result_ready &&
          (exu_result.uop.fu_type == FU_BRANCH) && !exu_result.uop.exception_valid
      ),
      .resolved_control_flow_op_i(exu_result.uop.branch_ctrl.op),
      .resolved_control_flow_pc_i(exu_result.uop.pc),
      .resolved_control_flow_taken_i(
          (exu_result.uop.branch_ctrl.op != CF_BRANCH) ||
          (exu_result.next_pc !=
           (exu_result.uop.pc + program_counter_t'(INSTRUCTION_BYTES)))
      ),
      .resolved_control_flow_immediate_i(exu_result.uop.imm),
      .lsu_request_occurred_i(lsu_req_valid && lsu_req_ready),
      .lsu_request_memory_cmd_i(lsu_req.uop.mem_ctrl.cmd),
      .lsu_read_address_occurred_i(data_axi4_manager_o.ar_valid && data_axi4_manager_i.ar_ready),
      .lsu_read_response_occurred_i(data_axi4_manager_i.r_valid && data_axi4_manager_o.r_ready),
      .lsu_write_address_occurred_i(data_axi4_manager_o.aw_valid && data_axi4_manager_i.aw_ready),
      .lsu_write_data_occurred_i(data_axi4_manager_o.w_valid && data_axi4_manager_i.w_ready),
      .lsu_write_response_occurred_i(data_axi4_manager_i.b_valid && data_axi4_manager_o.b_ready),
      .icache_cacheable_hit_count_i(sim_icache_cacheable_hit_count),
      .icache_cacheable_miss_response_count_i(sim_icache_cacheable_miss_response_count),
      .icache_hit_latency_cycle_sum_i(sim_icache_hit_latency_cycle_sum),
      .icache_miss_response_latency_cycle_sum_i(sim_icache_miss_response_latency_cycle_sum)
  );

  // Cache性能统计只存在于仿真配置。它观察I-cache定义的语义事件，不从AXI
  // beat反推hit/miss，因此不会把一次cache line refill误计成多次miss。
  riscv32_sim_icache_performance_monitor u_sim_icache_performance_monitor (
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
  riscv32_sim_dcache_performance_monitor u_sim_dcache_performance_monitor (
      .clk_i         (clk_i),
      .rst_ni        (rst_ni),
      .dcache_event_i(dcache_event)
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
      .redirect_req_o      (commit_redirect_req_at_resolution),
      .redirect_req_valid_o(commit_redirect_resolution_occurred)
  );

  assign execute_redirect_req_at_resolution = exu_result.redirect_req;
  assign execute_redirect_resolution_occurred = exu_result_valid && exu_result_ready &&
                                                exu_result.redirect_valid;

  // Every redirect source crosses the same registered frontend boundary. Pipeline flushes
  // still use the raw discovery events below, so this timing register does not permit a
  // younger instruction to execute or commit while frontend recovery is pending.
  riscv32_frontend_redirect_register u_execute_redirect_register (
      .clk_i                          (clk_i),
      .rst_ni                         (rst_ni),
      .redirect_req_i                 (execute_redirect_req_at_resolution),
      .redirect_req_valid_i           (execute_redirect_resolution_occurred),
      .cancel_i                       (commit_redirect_occurred),
      .registered_redirect_req_o      (redirect_req[EXU_REDIRECT_INDEX]),
      .registered_redirect_req_valid_o(execute_redirect_occurred)
  );

  assign redirect_req_valid[EXU_REDIRECT_INDEX] = execute_redirect_occurred;

  riscv32_frontend_redirect_register u_fence_i_redirect_register (
      .clk_i                          (clk_i),
      .rst_ni                         (rst_ni),
      .redirect_req_i                 (fence_i_redirect_req),
      .redirect_req_valid_i           (committed_fence_i_occurred),
      .cancel_i                       (1'b0),
      .registered_redirect_req_o      (redirect_req[FENCE_I_REDIRECT_INDEX]),
      .registered_redirect_req_valid_o(redirect_req_valid[FENCE_I_REDIRECT_INDEX])
  );

  riscv32_frontend_redirect_register u_commit_redirect_register (
      .clk_i                          (clk_i),
      .rst_ni                         (rst_ni),
      .redirect_req_i                 (commit_redirect_req_at_resolution),
      .redirect_req_valid_i           (commit_redirect_resolution_occurred),
      .cancel_i                       (1'b0),
      .registered_redirect_req_o      (redirect_req[COMMIT_REDIRECT_INDEX]),
      .registered_redirect_req_valid_o(redirect_req_valid[COMMIT_REDIRECT_INDEX])
  );

  // trap/mret和fence.i都在提交边界恢复控制流。它们必须清除同拍可能到达WB的年轻结果；
  // 普通EX分支redirect只清除更年轻的ID/EX内容，不能清除分支自身的完成结果。
  // 原始EX/commit事件立即阻止并清除年轻后端指令；所有redirect在下一拍经过统一寄存边界
  // 到达IFU。fetch buffer只使用这个寄存事件，避免commit/EX组合逻辑进入前端ready路径。
  // hazard controller也观察寄存事件，确保redirect应用当拍没有旧fetch entry越过ID边界。
  assign commit_redirect_occurred = commit_redirect_resolution_occurred ||
                                    committed_fence_i_occurred;
  assign frontend_recovery_occurred = selected_redirect_req_valid;

  riscv32_redirect_arbiter #(
      .SOURCE_COUNT(REDIRECT_SOURCE_COUNT)
  ) u_redirect_arbiter (
      .redirect_req_i               (redirect_req),
      .redirect_req_valid_i         (redirect_req_valid),
      .selected_redirect_req_o      (selected_redirect_req),
      .selected_redirect_req_valid_o(selected_redirect_req_valid)
  );

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
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    icache_invalidate_req |-> icache_busy)
  else $error("I-cache dropped busy while an invalidate transaction was pending");

  a_dcache_clean_request_means_busy :
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    dcache_clean_req |-> dcache_busy)
  else $error("D-cache dropped busy while a clean transaction was pending");

  a_dcache_clean_fault_is_reported :
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    !dcache_clean_access_fault)
  else $error("D-cache writeback failed during fence.i maintenance");

  // 精确异常只允许在commit成为架构事件。该拍必须阻止更年轻的EX指令发出副作用，
  // 并同时清空ID/EX与可能同拍进入WB的年轻completion。
  a_committed_exception_flushes_younger_instructions :
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (commit_valid && commit.trap_taken) |->
    (commit_redirect_occurred && decode_execute_flush && writeback_flush &&
     !execute_issue_allowed))
  else $error("committed exception did not block and flush younger pipeline work");

  a_registered_execute_redirect_blocks_younger_execute :
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    execute_redirect_occurred |->
      (decode_execute_flush && !execute_issue_allowed && !lsu_req_valid))
  else $error("registered execute redirect allowed a wrong-path EX side effect");

  /* verilator lint_on SYNCASYNCNET */
`endif

endmodule
