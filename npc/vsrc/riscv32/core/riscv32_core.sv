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
    input logic timer_interrupt_i,

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
  logic icache_lookup_stalled_q;

  typedef enum logic [1:0] {
    FENCE_I_MAINTENANCE_IDLE,
    FENCE_I_DRAIN_FRONTEND,
    FENCE_I_CLEAN_DCACHE,
    FENCE_I_INVALIDATE_ICACHE
  } fence_i_maintenance_state_e;

  fence_i_maintenance_state_e fence_i_maintenance_state_q;
  fence_i_maintenance_state_e fence_i_maintenance_state_d;

  // 预测查询先于I-cache运行；IFU内部的窄请求队列保存PC、epoch、tag和prediction。
  // fetch queue保存已经返回的指令。两级队列分别切断预测/I-cache与I-cache/IDU反压路径。
  fetch_entry_t ifu_fetch_entry;
  logic ifu_fetch_entry_valid;
  logic ifu_fetch_entry_ready;
  program_counter_t next_pc_predictor_lookup_request_pc;
  fetch_epoch_t next_pc_predictor_lookup_request_epoch;
  logic next_pc_predictor_lookup_request_valid;
  logic next_pc_predictor_lookup_request_ready;
  program_counter_t next_pc_predictor_lookup_response_pc;
  fetch_epoch_t next_pc_predictor_lookup_response_epoch;
  branch_prediction_t next_pc_predictor_prediction;
  logic next_pc_predictor_lookup_response_valid;
  logic next_pc_predictor_lookup_response_ready;
  logic next_pc_predictor_flush;
  program_counter_t resolved_control_flow_target;
  logic fetch_taken_prediction_occurred;
  fetch_entry_t idu_fetch_entry;
  logic idu_fetch_entry_valid;
  logic idu_fetch_entry_ready;

  decoded_uop_t idu_decoded_uop;
  logic idu_decoded_uop_valid;
  logic idu_decoded_uop_ready;
  decoded_uop_t decoded_uop;
  logic decoded_uop_valid;
  logic decoded_uop_ready;

  // decode stage之后先锁存原始寄存器读值，再完成操作数选择和前递并进入ID/EX。
  // 名称显式标出每个流水边界两侧，避免把组合值误认为已经寄存的状态。
  xlen_data_t rs1_value;
  xlen_data_t rs2_value;
  execute_packet_t decoded_register_read_packet;
  logic decoded_register_read_packet_ready;
  execute_packet_t register_read_packet;
  logic register_read_packet_valid;
  logic register_read_packet_ready;
  execute_packet_t decoded_execute_packet;
  logic decoded_execute_packet_valid;
  logic decoded_execute_packet_ready;
  execute_packet_t execute_packet;
  logic execute_packet_valid;
  logic execute_packet_ready;

  execute_result_t exu_result;
  logic exu_result_valid;
  logic exu_result_ready;
  execute_result_t resolved_execute_result;
  logic resolved_execute_result_valid;
  logic resolved_execute_result_ready;

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
  logic commit_redirect_resolution_occurred;

  xlen_data_t gpr_write_data;
  arch_reg_idx_t gpr_write_addr;
  logic gpr_write_enable;

  xlen_data_t csr_read_data;
  logic csr_read_illegal;
  program_counter_t csr_mtvec;
  program_counter_t csr_mepc;
  logic retired_instruction_occurred;

  logic timer_interrupt_enabled;
  logic interrupt_issue_hold;
  logic interrupt_valid;
  program_counter_t interrupt_pc;

  logic trap_valid;
  program_counter_t trap_pc;
  xlen_data_t trap_cause;
  xlen_data_t trap_tval;
  logic mret_valid;

  redirect_req_t redirect_req_at_resolution[REDIRECT_SOURCE_COUNT];
  logic [REDIRECT_SOURCE_COUNT-1:0] redirect_req_at_resolution_valid;
  redirect_req_t selected_redirect_req;
  logic selected_redirect_req_valid;

  logic decode_accept_allowed;
  logic execute_progress_allowed;
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
  logic commit_redirect_occurred;
  logic frontend_recovery_occurred;
  logic execute_forwardable_producer_present;
  logic execute_blocking_producer_present;
  logic execute_serializing_instruction_present;
  logic execute_result_forwarding_available;
  logic writeback_forwarding_available;
  logic rs1_execute_forwarding_selected;
  logic rs1_execute_result_forwarding_selected;
  logic rs1_writeback_forwarding_selected;
  logic rs2_execute_forwarding_selected;
  logic rs2_execute_result_forwarding_selected;
  logic rs2_writeback_forwarding_selected;

  always_comb begin
    decoded_register_read_packet                = '0;
    decoded_register_read_packet.uop            = decoded_uop;
    decoded_register_read_packet.source_a_value =
        (gpr_write_enable && (gpr_write_addr == decoded_uop.rs1) && (decoded_uop.rs1 != '0)) ?
        gpr_write_data : rs1_value;
    decoded_register_read_packet.source_b_value =
        (gpr_write_enable && (gpr_write_addr == decoded_uop.rs2) && (decoded_uop.rs2 != '0)) ?
        gpr_write_data : rs2_value;
    decoded_register_read_packet.csr_rdata      = '0;
    decoded_register_read_packet.csr_illegal    = 1'b0;

    decoded_execute_packet             = register_read_packet;
    decoded_execute_packet.csr_rdata   = csr_read_data;
    decoded_execute_packet.csr_illegal = csr_read_illegal;

    // 整数操作数选择在ID/EX寄存边界之前完成。其他执行类型仍需要真实rs1/rs2：
    // branch用它们比较，LSU用它们形成地址/写数据，CSR用source_a形成寄存器操作数。
    if (register_read_packet.uop.fu_type == FU_INT) begin
      unique case (register_read_packet.uop.int_ctrl.operand_a_sel)
        OPA_RS1: decoded_execute_packet.source_a_value = register_read_packet.source_a_value;
        OPA_PC:  decoded_execute_packet.source_a_value =
            xlen_data_t'(register_read_packet.uop.pc);
        default: decoded_execute_packet.source_a_value = '0;
      endcase

      unique case (register_read_packet.uop.int_ctrl.operand_b_sel)
        OPB_RS2: decoded_execute_packet.source_b_value = register_read_packet.source_b_value;
        OPB_IMM: decoded_execute_packet.source_b_value = register_read_packet.uop.imm;
        default: decoded_execute_packet.source_b_value = '0;
      endcase
    end

    // 所有旁路都在消费者写入ID/EX时完成。当前EX生产者的组合结果在该时钟沿前已经
    // 稳定，可以和EX/MEM、WB结果一样直接写入payload。LSU结果必须先跨过WB寄存边界，
    // 避免把存储系统response与ID/EX操作数选择串成关键路径。这样普通相关指令仍可连续
    // 发射，同时不把“旁路mux + 当前指令ALU”串在同一条EX关键路径上。
    if (rs1_writeback_forwarding_selected) begin
      decoded_execute_packet.source_a_value = writeback_result.result;
    end
    if (rs2_writeback_forwarding_selected) begin
      decoded_execute_packet.source_b_value = writeback_result.result;
    end
    if (rs1_execute_result_forwarding_selected) begin
      decoded_execute_packet.source_a_value = resolved_execute_result.result;
    end
    if (rs2_execute_result_forwarding_selected) begin
      decoded_execute_packet.source_b_value = resolved_execute_result.result;
    end
    if (rs1_execute_forwarding_selected) begin
      decoded_execute_packet.source_a_value = exu_result.result;
    end
    if (rs2_execute_forwarding_selected) begin
      decoded_execute_packet.source_b_value = exu_result.result;
    end
  end

  riscv32_ifu #(
      .PC_START(RESET_PC)
  ) u_ifu (
      .clk_i(clk_i),
      .rst_ni(rst_ni),
      .redirect_req_i(selected_redirect_req),
      .redirect_req_valid_i(selected_redirect_req_valid),
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

  riscv32_icache u_icache (
      .clk_i(clk_i),
      .rst_ni(rst_ni),
      .lookup_req_i(icache_lookup_req),
      .lookup_req_valid_i(icache_lookup_req_valid && frontend_memory_access_allowed),
      .lookup_req_ready_o(icache_lookup_req_ready),
      .lookup_resp_o(icache_lookup_resp),
      .lookup_resp_valid_o(icache_lookup_resp_valid),
      .lookup_resp_ready_i(icache_lookup_resp_ready),
      .invalidate_req_i(icache_invalidate_req),
      .invalidate_done_o(icache_invalidate_done),
      .cache_busy_o(icache_busy),
      .refill_req_o(icache_refill_req),
      .refill_req_valid_o(icache_refill_req_valid),
      .refill_req_ready_i(icache_refill_req_ready),
      .refill_resp_i(icache_refill_resp),
      .refill_resp_valid_i(icache_refill_resp_valid),
      .refill_resp_ready_o(icache_refill_resp_ready),
      .event_o(icache_event)
  );

  riscv32_fetch_buffer u_fetch_buffer (
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

  // 预测器在I-cache之前运行。预测响应与下一次预测请求可以同拍握手；IFU用frontend
  // tag保存预测元数据，I-cache响应不再组合反馈到下一次预测和取指请求。
  assign resolved_control_flow_target =
      (resolved_execute_result.uop.branch_ctrl.op == CF_JALR) ?
      resolved_execute_result.next_pc :
      resolved_execute_result.uop.pc +
      program_counter_t'(resolved_execute_result.uop.imm);

  riscv32_fetch_control_flow_predictor u_fetch_control_flow_predictor (
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
      .resolved_control_flow_occurred_i   (
          resolved_execute_result_valid && resolved_execute_result_ready &&
          (resolved_execute_result.uop.fu_type == FU_BRANCH) &&
          !resolved_execute_result.uop.exception_valid
      ),
      .resolved_control_flow_taken_i      (
          (resolved_execute_result.uop.branch_ctrl.op != CF_BRANCH) ||
          (resolved_execute_result.next_pc !=
           (resolved_execute_result.uop.pc + program_counter_t'(INSTRUCTION_BYTES)))
      ),
      .flush_lookup_i(next_pc_predictor_flush),
      .invalidate_i(icache_invalidate_req)
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
  // 维护开始时，已经对外有效但未握手的请求不能撤回。只允许这一项继续交付，
  // DRAIN 等它及缓存中的旧事务完成后再清理；后续新请求一直保持暂停。
  assign frontend_memory_access_allowed = !fence_i_maintenance_active || icache_lookup_stalled_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      icache_lookup_stalled_q <= 1'b0;
    end else begin
      icache_lookup_stalled_q <= icache_lookup_req_valid && frontend_memory_access_allowed &&
                                !icache_lookup_req_ready;
    end
  end
  assign dcache_clean_req = fence_i_maintenance_state_q == FENCE_I_CLEAN_DCACHE;
  assign icache_invalidate_req = fence_i_maintenance_state_q == FENCE_I_INVALIDATE_ICACHE;

  always_comb begin
    fence_i_maintenance_state_d = fence_i_maintenance_state_q;
    unique case (fence_i_maintenance_state_q)
      FENCE_I_MAINTENANCE_IDLE: begin
        if (committed_fence_i_occurred) begin
          fence_i_maintenance_state_d = FENCE_I_DRAIN_FRONTEND;
        end
      end
      FENCE_I_DRAIN_FRONTEND: begin
        if (!icache_lookup_stalled_q && !icache_busy) begin
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

  // IDU 直接送入寄存器读级，减少一组 uop 寄存器及分支恢复延迟。
  // 寄存器读级仍负责反压与 flush；前递和冒险判断仍从其寄存输出开始。
  assign decoded_uop           = idu_decoded_uop;
  assign decoded_uop_valid     = idu_decoded_uop_valid;
  assign idu_decoded_uop_ready  = decoded_uop_ready;

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
      .csr_read_enable_i             (register_read_packet_valid &&
                                      register_read_packet.uop.csr_ctrl.read_enable),
      .csr_read_addr_i               (register_read_packet.uop.csr_ctrl.addr),
      .csr_access_write_enable_i     (register_read_packet_valid &&
                                      register_read_packet.uop.csr_ctrl.write_enable),
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
      .timer_interrupt_i             (timer_interrupt_i),
      .timer_interrupt_enabled_o     (timer_interrupt_enabled),
      .mtvec_o                       (csr_mtvec),
      .mepc_o                        (csr_mepc)
  );

  // GPR/CSR异步读结果在这里跨越独立寄存边界。同一个上升沿发生WB写入与读取时，
  // decoded_register_read_packet中的显式写优先旁路保证捕获新值，而不是阵列旧值。
  riscv32_register_read_stage u_register_read_stage (
      .clk_i                               (clk_i),
      .rst_ni                              (rst_ni),
      .decoded_register_read_packet_i      (decoded_register_read_packet),
      .decoded_register_read_packet_valid_i(decoded_uop_valid),
      .decoded_register_read_packet_ready_o(decoded_register_read_packet_ready),
      .register_read_packet_o              (register_read_packet),
      .register_read_packet_valid_o        (register_read_packet_valid),
      .register_read_packet_ready_i        (register_read_packet_ready),
      .gpr_write_enable_i                  (gpr_write_enable),
      .gpr_write_addr_i                    (gpr_write_addr),
      .gpr_write_data_i                    (gpr_write_data),
      .flush_i                             (decode_execute_flush)
  );

  assign decoded_uop_ready = decoded_register_read_packet_ready;

  assign execute_result_forwarding_available = resolved_execute_result_valid &&
                                                resolved_execute_result.uop.writes_rd &&
                                                !resolved_execute_result.uop.exception_valid;
  assign writeback_forwarding_available = writeback_result_valid &&
                                          writeback_result.uop.writes_rd &&
                                          !writeback_result.uop.exception_valid;
  riscv32_pipeline_hazard_controller u_pipeline_hazard_controller (
      .clk_i(clk_i),
      .rst_ni(rst_ni),
      .decoded_uop_valid_i(register_read_packet_valid),
      .decoded_uses_rs1_i(register_read_packet.uop.uses_rs1),
      .decoded_rs1_i(register_read_packet.uop.rs1),
      .decoded_uses_rs2_i(register_read_packet.uop.uses_rs2),
      .decoded_rs2_i(register_read_packet.uop.rs2),
      .decoded_serializing_i(register_read_packet.uop.serializing),
      .execute_instruction_present_i(execute_packet_valid),
      .execute_forwardable_producer_present_i(execute_forwardable_producer_present),
      .execute_blocking_producer_present_i(execute_blocking_producer_present),
      .execute_rd_i(execute_packet.uop.rd),
      .execute_serializing_instruction_present_i(execute_serializing_instruction_present),
      .execute_result_valid_i(resolved_execute_result_valid),
      .execute_result_ready_i(resolved_execute_result_ready),
      .execute_result_writes_rd_i(resolved_execute_result.uop.writes_rd),
      .execute_result_rd_i(resolved_execute_result.uop.rd),
      .execute_result_forwarding_available_i(execute_result_forwarding_available),
      .execute_result_serializing_i(resolved_execute_result.uop.serializing),
      .writeback_result_valid_i(writeback_result_valid),
      .writeback_writes_rd_i(writeback_result.uop.writes_rd),
      .writeback_rd_i(writeback_result.uop.rd),
      .writeback_serializing_i(writeback_result.uop.serializing),
      .writeback_forwarding_available_i(writeback_forwarding_available),
      .lsu_busy_i(lsu_transaction_active),
      .lsu_completion_succeeded_i(lsu_writeback_valid && lsu_writeback_ready &&
                                  !lsu_writeback.uop.exception_valid),
      .lsu_pending_writes_rd_i(lsu_pending_writes_rd),
      .lsu_pending_rd_i(lsu_pending_rd),
      .execute_redirect_present_i  (resolved_execute_result_valid &&
                                    resolved_execute_result.redirect_valid),
      .frontend_redirect_applied_i(selected_redirect_req_valid),
      .commit_redirect_occurred_i(commit_redirect_occurred),
      .decode_accept_allowed_o(decode_accept_allowed),
      .execute_progress_allowed_o(execute_progress_allowed),
      .execute_issue_allowed_o(execute_issue_allowed),
      .decode_execute_flush_o(decode_execute_flush),
      .writeback_flush_o(writeback_flush),
      .raw_hazard_present_o(raw_hazard_present),
      .serializing_hazard_present_o(serializing_hazard_present),
      .structural_hazard_present_o(structural_hazard_present),
      .rs1_execute_forwarding_selected_o(rs1_execute_forwarding_selected),
      .rs1_execute_result_forwarding_selected_o(rs1_execute_result_forwarding_selected),
      .rs1_writeback_forwarding_selected_o(rs1_writeback_forwarding_selected),
      .rs2_execute_forwarding_selected_o(rs2_execute_forwarding_selected),
      .rs2_execute_result_forwarding_selected_o(rs2_execute_result_forwarding_selected),
      .rs2_writeback_forwarding_selected_o(rs2_writeback_forwarding_selected)
  );

  // valid和ready同时受冒险策略约束，保证被停顿的fetch entry仍由IFU/I-cache持有，
  // 不会出现“stage没有保存，但上游认为已经交付”的消息丢失。
  assign decoded_execute_packet_valid = register_read_packet_valid && decode_accept_allowed &&
                                         !interrupt_issue_hold;
  assign register_read_packet_ready   = decoded_execute_packet_ready && decode_accept_allowed &&
                                         !interrupt_issue_hold;

  riscv32_decode_execute_stage u_decode_execute_stage (
      .clk_i                         (clk_i),
      .rst_ni                        (rst_ni),
      .decoded_execute_packet_i      (decoded_execute_packet),
      .decoded_execute_packet_valid_i(decoded_execute_packet_valid),
      .decoded_execute_packet_ready_o(decoded_execute_packet_ready),
      .execute_packet_o              (execute_packet),
      .execute_packet_valid_o        (execute_packet_valid),
      .execute_packet_ready_i        (execute_packet_ready && execute_progress_allowed),
      .execute_forwardable_producer_present_o(execute_forwardable_producer_present),
      .execute_blocking_producer_present_o(execute_blocking_producer_present),
      .execute_serializing_instruction_present_o(execute_serializing_instruction_present),
      .flush_i                       (decode_execute_flush)
  );

  riscv32_exu u_exu (
      .execute_packet_i              (execute_packet),
      .execute_packet_valid_i        (execute_packet_valid),
      .execute_packet_issue_allowed_i(execute_issue_allowed),
      .execute_packet_ready_o        (execute_packet_ready),
      .exu_result_o                  (exu_result),
      .exu_result_valid_o            (exu_result_valid),
      .exu_result_ready_i            (exu_result_ready),
      .lsu_req_o                     (lsu_req),
      .lsu_req_valid_o               (lsu_req_valid),
      .lsu_req_ready_i               (lsu_req_ready)
  );

  // EX1在EXU中计算真实结果，EX2从本寄存级校验控制流预测。普通整数结果可滚动通过；
  // 本级寄存结果同时旁路到下一条消费者的EXU输入，不反馈到ID/EX输入。
  riscv32_execute_result_stage u_execute_result_stage (
      .clk_i                  (clk_i),
      .rst_ni                 (rst_ni),
      .executed_result_i      (exu_result),
      .executed_result_valid_i(exu_result_valid),
      .executed_result_ready_o(exu_result_ready),
      .resolved_result_o      (resolved_execute_result),
      .resolved_result_valid_o(resolved_execute_result_valid),
      .resolved_result_ready_i(resolved_execute_result_ready),
      // 执行级分支恢复取消同拍进入EX/MEM的更年轻普通结果；提交级恢复处理异常、
      // mret和fence.i等更晚发现的恢复事件。两者都只清寄存级valid。
      .flush_i                (execute_redirect_resolution_occurred || commit_redirect_occurred)
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

  riscv32_completion_mux u_completion_mux (
      .exu_result_i            (resolved_execute_result),
      .exu_result_valid_i      (resolved_execute_result_valid),
      .exu_result_ready_o      (resolved_execute_result_ready),
      .lsu_writeback_i         (lsu_writeback),
      .lsu_writeback_valid_i   (lsu_writeback_valid),
      .lsu_writeback_ready_o   (lsu_writeback_ready),
      .writeback_result_o      (completion_result),
      .writeback_result_valid_o(completion_result_valid),
      .writeback_result_ready_i(completion_result_ready)
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
  riscv32_sim_issue_window_monitor u_sim_issue_window_monitor (
      .clk_i                         (clk_i),
      .rst_ni                        (rst_ni),
      .commit_valid_i                (commit_valid),
      .commit_i                      (commit),
      .issue_occurred_i               ((exu_result_valid && exu_result_ready) ||
                                      (lsu_req_valid && lsu_req_ready)),
      .execute_valid_i               (execute_packet_valid),
      .redirect_occurred_i            (execute_redirect_resolution_occurred || commit_redirect_occurred),
      .lsu_busy_i                    (lsu_transaction_active),
      .execute_result_blocked_i      (resolved_execute_result_valid && !resolved_execute_result_ready),
      .register_read_valid_i         (register_read_packet_valid),
      .raw_hazard_present_i          (raw_hazard_present),
      .serializing_hazard_present_i  (serializing_hazard_present),
      .icache_event_i                (icache_event),
      .dcache_event_i                (dcache_event)
  );

  // lookup request/response属于IFU与I-cache边界；delivery和waiting属于IFU与IDU边界。
  // 分开统计才能区分cache等待与译码反压。
  riscv32_sim_performance_monitor u_sim_performance_monitor (
      .clk_i(clk_i),
      .rst_ni(rst_ni),
      .ifu_instruction_request_occurred_i(
          icache_lookup_req_valid && icache_lookup_req_ready && frontend_memory_access_allowed
      ),
      .ifu_instruction_request_waiting_i(
          icache_lookup_req_valid &&
          (!icache_lookup_req_ready || !frontend_memory_access_allowed)
      ),
      .ifu_instruction_response_occurred_i(
          icache_lookup_resp_valid && icache_lookup_resp_ready
      ),
      .ifu_instruction_response_discarded_occurred_i(
          icache_lookup_resp_valid && icache_lookup_resp_ready && !ifu_fetch_entry_valid
      ),
      .ifu_instruction_delivery_occurred_i(idu_fetch_entry_valid && idu_fetch_entry_ready),
      .ifu_downstream_waiting_i(idu_fetch_entry_valid && !idu_fetch_entry_ready),
      .icache_miss_occurred_i(icache_event.miss_occurred),
      .instruction_decode_occurred_i(idu_decoded_uop_valid && idu_decoded_uop_ready),
      .decoded_fu_type_i(idu_decoded_uop.fu_type),
      .decoded_memory_cmd_i(idu_decoded_uop.mem_ctrl.cmd),
      .exu_completion_occurred_i(resolved_execute_result_valid && resolved_execute_result_ready),
      .lsu_completion_occurred_i(lsu_writeback_valid && lsu_writeback_ready),
      .instruction_retirement_occurred_i(retired_instruction_occurred),
      .pipeline_raw_hazard_waiting_i(raw_hazard_present),
      .pipeline_serializing_waiting_i(serializing_hazard_present),
      .pipeline_structural_waiting_i(structural_hazard_present && register_read_packet_valid),
      .frontend_supply_waiting_i(!register_read_packet_valid && !structural_hazard_present &&
                                 !commit_redirect_occurred),
      .pipeline_control_flush_occurred_i(frontend_recovery_occurred),
      .pipeline_execute_instruction_discarded_i(commit_redirect_occurred && execute_packet_valid),
      .fetch_taken_prediction_occurred_i(fetch_taken_prediction_occurred),
      // 性能分类必须在EX结果有效的原始拍采样op；registered redirect晚一拍，
      // 若用它与当前exu_result配对，会把纠错归到下一条无关指令。
      .execute_misprediction_redirect_occurred_i(execute_redirect_resolution_occurred),
      .control_flow_resolution_occurred_i(
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

  // 在 ID/EX 入口暂停新工作，后端继续排空；前端待发指令由受理后的 flush 清除。
  riscv32_interrupt_controller #(
      .RESET_PC(RESET_PC)
  ) u_interrupt_controller (
      .clk_i                    (clk_i),
      .rst_ni                   (rst_ni),
      .timer_interrupt_enabled_i(timer_interrupt_enabled),
      .backend_busy_i           (execute_packet_valid || resolved_execute_result_valid ||
                                 lsu_transaction_active || writeback_result_valid),
      .maintenance_busy_i       (fence_i_maintenance_active || dcache_busy ||
                                 selected_redirect_req_valid),
      .commit_valid_i           (commit_valid),
      .commit_i                 (commit),
      .redirect_valid_i         (commit_redirect_resolution_occurred),
      .redirect_i               (commit_redirect_req_at_resolution),
      .issue_hold_o             (interrupt_issue_hold),
      .interrupt_valid_o        (interrupt_valid),
      .interrupt_pc_o           (interrupt_pc)
  );

  riscv32_trap_controller u_trap_controller (
      .commit_i            (commit),
      .commit_valid_i      (commit_valid),
      .interrupt_valid_i   (interrupt_valid),
      .interrupt_pc_i      (interrupt_pc),
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

  assign execute_redirect_req_at_resolution = resolved_execute_result.redirect_req;
  assign execute_redirect_resolution_occurred =
      resolved_execute_result_valid && resolved_execute_result_ready &&
      resolved_execute_result.redirect_valid;

  // 各来源的请求数据直接进入自己的采样寄存器；优先级逻辑只选择来源索引。
  // commit位于最高下标，因此同拍发生多个请求时，精确异常或mret优先于fence.i和
  // 推测执行恢复。交给IFU和流水线flush的valid直接来自统一恢复边界的触发器。
  assign redirect_req_at_resolution[EXU_REDIRECT_INDEX] =
      execute_redirect_req_at_resolution;
  assign redirect_req_at_resolution_valid[EXU_REDIRECT_INDEX] =
      execute_redirect_resolution_occurred;
  assign redirect_req_at_resolution[FENCE_I_REDIRECT_INDEX] = fence_i_redirect_req;
  assign redirect_req_at_resolution_valid[FENCE_I_REDIRECT_INDEX] =
      committed_fence_i_occurred;
  assign redirect_req_at_resolution[COMMIT_REDIRECT_INDEX] =
      commit_redirect_req_at_resolution;
  assign redirect_req_at_resolution_valid[COMMIT_REDIRECT_INDEX] =
      commit_redirect_resolution_occurred;

  riscv32_frontend_redirect_register #(
      .SOURCE_COUNT(REDIRECT_SOURCE_COUNT)
  ) u_frontend_redirect_register (
      .clk_i                          (clk_i),
      .rst_ni                         (rst_ni),
      .redirect_req_i                 (redirect_req_at_resolution),
      .redirect_req_valid_i           (redirect_req_at_resolution_valid),
      .registered_redirect_req_o      (selected_redirect_req),
      .registered_redirect_req_valid_o(selected_redirect_req_valid)
  );

  // trap/mret必须在提交边界立即清除更年轻的后端工作。FENCE.I已经被IDU标记为
  // serializing：它只有在所有老指令排空后才能进入，且在自己提交前不会接收年轻指令，
  // 因此提交拍不需要再通过通用commit flush组合地kill LSU。FENCE.I的前端恢复仍经过
  // u_frontend_redirect_register，并与D-cache clean、I-cache invalidate维护状态机协同。
  // 将两类事件分开也避免commit -> LSU -> D-cache array的跨模块关键路径。
  assign commit_redirect_occurred = commit_redirect_resolution_occurred;
  assign frontend_recovery_occurred = selected_redirect_req_valid;

`ifndef SYNTHESIS
  // rst_ni是状态寄存器的异步复位，同时也是SVA的disable条件。Verilator会把后者
  // 视为同步使用并报告SYNCASYNCNET；该诊断不代表复位网络存在功能冲突。
  /* verilator lint_off SYNCASYNCNET */
  a_interrupt_has_no_instruction_side_effects :
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    interrupt_valid |-> (!commit_valid && !execute_packet_valid &&
                         !resolved_execute_result_valid && !lsu_transaction_active &&
                         !lsu_req_valid && !gpr_write_enable && !decoded_execute_packet_valid))
  else $error("interrupt accepted before the execution pipeline drained");

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

  a_dcache_clean_fault_is_reported :
  assert property (@(posedge clk_i) disable iff (!rst_ni) !dcache_clean_access_fault)
  else $error("D-cache writeback failed during fence.i maintenance");

  // FENCE.I依靠serializing语义排空后端，而不是在提交拍用组合flush补救。该性质成立时，
  // committed_fence_i_occurred可以只启动已寄存的重定向和cache维护事务。
  a_committed_fence_i_has_no_younger_backend_work :
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    committed_fence_i_occurred |->
    (!execute_packet_valid && !resolved_execute_result_valid && !lsu_transaction_active))
  else $error("FENCE.I committed while younger backend work was still present");

  // 精确异常只允许在commit成为架构事件。该拍必须阻止更年轻的EX指令发出副作用，
  // 并同时清空ID/EX与可能同拍进入WB的年轻completion。
  a_committed_exception_flushes_younger_instructions :
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (commit_valid && commit.trap_taken) |->
    (commit_redirect_occurred && decode_execute_flush && writeback_flush &&
     !execute_issue_allowed))
  else $error("committed exception did not block and flush younger pipeline work");

  // 只有 LSU 已成功交付 WB，才允许年轻普通指令在同拍进入空 EX 结果级。
  a_lsu_completion_overlap_preserves_order :
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (lsu_transaction_active && exu_result_valid && exu_result_ready) |->
    (lsu_writeback_valid && lsu_writeback_ready && !lsu_writeback.uop.exception_valid &&
     !resolved_execute_result_valid))
  else $error("younger execution crossed an unfinished or faulting LSU transaction");

  a_resolved_execute_redirect_blocks_younger_execute :
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (resolved_execute_result_valid && resolved_execute_result.redirect_valid) |->
      (decode_execute_flush && !execute_issue_allowed && !lsu_req_valid))
  else $error("resolved execute redirect allowed a wrong-path EX side effect");

  /* verilator lint_on SYNCASYNCNET */
`endif

endmodule
