// 前端控制流预测器。
//
// 小容量BTB/BHT/RAS查询拆成两级流水：第一级读取所选表项，第二级完成tag比较和
// 目标选择。两个弹性级都支持同拍移出旧项并接收新项，因此非跳转路径仍可保持
// 每拍一次查询，同时不再把数组选择和预测判定串在同一条关键路径上。
module riscv32_fetch_control_flow_predictor
  import riscv32_pkg::*;
#(
    parameter int unsigned BHT_ENTRY_COUNT = riscv_config_pkg::BRANCH_HISTORY_ENTRY_COUNT,
    parameter int unsigned BTB_ENTRY_COUNT = riscv_config_pkg::BRANCH_TARGET_ENTRY_COUNT,
    parameter int unsigned BTB_WAY_COUNT   = riscv_config_pkg::BRANCH_TARGET_WAY_COUNT,
    parameter int unsigned RAS_ENTRY_COUNT = riscv_config_pkg::RETURN_STACK_ENTRY_COUNT
) (
    input  logic clk_i,
    input  logic rst_ni,

    input  program_counter_t   lookup_request_pc_i,
    input  fetch_epoch_t       lookup_request_epoch_i,
    input  logic               lookup_request_valid_i,
    output logic               lookup_request_ready_o,
    output program_counter_t   lookup_response_pc_o,
    output fetch_epoch_t       lookup_response_epoch_o,
    output branch_prediction_t lookup_prediction_o,
    output program_counter_t   lookup_next_pc_o,
    output logic               lookup_response_valid_o,
    input  logic               lookup_response_ready_i,

    input  program_counter_t resolved_control_flow_pc_i,
    input  program_counter_t resolved_control_flow_target_i,
    input  xlen_data_t       resolved_control_flow_imm_i,
    input  control_flow_op_e resolved_control_flow_op_i,
    input  arch_reg_idx_t    resolved_control_flow_rs1_i,
    input  arch_reg_idx_t    resolved_control_flow_rd_i,
    input  logic             resolved_control_flow_occurred_i,
    input  logic             resolved_control_flow_taken_i,

    // redirect只清除当前查询流水，不清除训练状态；fence.i才清除可能过期的BTB内容。
    input  logic flush_lookup_i,
    input  logic invalidate_i
);

  // 查询握手、两级有效位及最终预测选择由本模块统一管理。
  // BHT/BTB共享解析事件寄存器；RAS在相同边界并行保存自己的栈操作。
  typedef struct packed {
    logic             present;
    program_counter_t pc;
    program_counter_t target_pc;
    xlen_data_t       immediate;
    control_flow_op_e op;
    arch_reg_idx_t    rs1;
    arch_reg_idx_t    rd;
    logic             taken;
  } resolved_control_flow_update_t;

  typedef struct packed {
    program_counter_t pc;
    fetch_epoch_t     epoch;
    logic [1:0]       branch_history_counter;
    logic             return_target_present;
    program_counter_t return_target_pc;
  } lookup_query_t;

  typedef struct packed {
    program_counter_t   pc;
    fetch_epoch_t       epoch;
    branch_prediction_t prediction;
    program_counter_t   next_pc;
  } lookup_response_t;

  resolved_control_flow_update_t resolved_control_flow_update_q;
  lookup_query_t                 lookup_query_q;
  lookup_response_t              lookup_response_q;
  logic                          lookup_query_present_q;
  logic                          lookup_response_present_q;
  logic                          lookup_query_stage_ready;
  logic                          lookup_response_stage_ready;

  logic                lookup_capture;
  logic [1:0]          branch_history_lookup_counter;
  logic                return_target_present;
  program_counter_t    return_target_pc;
  logic                lookup_branch_target_present;
  branch_target_kind_e lookup_branch_target_kind;
  program_counter_t    lookup_branch_target_pc;
  logic                conditional_branch_predicted_taken;
  logic                predicted_taken;
  program_counter_t    predicted_target_pc;
  branch_prediction_t  lookup_prediction;
  program_counter_t    lookup_next_pc;

  // 两级弹性流水逐级传播ready。响应反压时仍可利用空闲查询级暂存一个请求；
  // 两级都被占用后才停止接收，不把下游ready直接接入BTB/BHT数据路径。
  assign lookup_response_stage_ready =
      !lookup_response_present_q || lookup_response_ready_i;
  assign lookup_query_stage_ready =
      !lookup_query_present_q || lookup_response_stage_ready;
  assign lookup_request_ready_o = lookup_query_stage_ready && !flush_lookup_i;
  assign lookup_response_pc_o    = lookup_response_q.pc;
  assign lookup_response_epoch_o = lookup_response_q.epoch;
  assign lookup_prediction_o     = lookup_response_q.prediction;
  assign lookup_next_pc_o        = lookup_response_q.next_pc;
  assign lookup_response_valid_o = lookup_response_present_q;

  assign lookup_capture = lookup_request_valid_i && lookup_request_ready_o;
  assign conditional_branch_predicted_taken = lookup_query_q.branch_history_counter[1];

  riscv32_branch_history_table #(
      .BHT_ENTRY_COUNT(BHT_ENTRY_COUNT)
  ) u_branch_history_table (
      .clk_i             (clk_i),
      .rst_ni            (rst_ni),
      .lookup_pc_i       (lookup_request_pc_i),
      .lookup_counter_o  (branch_history_lookup_counter),
      .training_pc_i     (resolved_control_flow_update_q.pc),
      .training_valid_i  (resolved_control_flow_update_q.present &&
                          (resolved_control_flow_update_q.op == CF_BRANCH)),
      .training_taken_i  (resolved_control_flow_update_q.taken)
  );

  riscv32_branch_target_buffer #(
      .BTB_ENTRY_COUNT(BTB_ENTRY_COUNT),
      .BTB_WAY_COUNT  (BTB_WAY_COUNT)
  ) u_branch_target_buffer (
      .clk_i                  (clk_i),
      .rst_ni                 (rst_ni),
      .lookup_request_pc_i    (lookup_request_pc_i),
      .lookup_capture_i       (lookup_capture),
      .lookup_query_pc_i      (lookup_query_q.pc),
      .lookup_query_valid_i   (lookup_query_present_q),
      .lookup_target_present_o(lookup_branch_target_present),
      .lookup_target_pc_o     (lookup_branch_target_pc),
      .lookup_target_kind_o   (lookup_branch_target_kind),
      .training_pc_i          (resolved_control_flow_update_q.pc),
      .training_target_pc_i   (resolved_control_flow_update_q.target_pc),
      .training_immediate_i   (resolved_control_flow_update_q.immediate),
      .training_op_i          (resolved_control_flow_update_q.op),
      .training_rs1_i         (resolved_control_flow_update_q.rs1),
      .training_rd_i          (resolved_control_flow_update_q.rd),
      .training_valid_i       (resolved_control_flow_update_q.present),
      .invalidate_i           (invalidate_i)
  );

  riscv32_return_address_stack #(
      .RAS_ENTRY_COUNT(RAS_ENTRY_COUNT)
  ) u_return_address_stack (
      .clk_i                            (clk_i),
      .rst_ni                           (rst_ni),
      .lookup_target_present_o          (return_target_present),
      .lookup_target_pc_o               (return_target_pc),
      .resolved_control_flow_pc_i       (resolved_control_flow_pc_i),
      .resolved_control_flow_imm_i      (resolved_control_flow_imm_i),
      .resolved_control_flow_op_i       (resolved_control_flow_op_i),
      .resolved_control_flow_rs1_i      (resolved_control_flow_rs1_i),
      .resolved_control_flow_rd_i       (resolved_control_flow_rd_i),
      .resolved_control_flow_occurred_i (resolved_control_flow_occurred_i),
      .resolved_control_flow_taken_i    (resolved_control_flow_taken_i),
      .invalidate_i                     (invalidate_i)
  );

  // BTB miss默认顺序取指。return优先采用RAS；RAS为空时退回BTB记录的上一次目标，
  // 错误目标仍会由EX按请求随身携带的prediction精确检查并恢复。
  always_comb begin
    predicted_taken     = 1'b0;
    predicted_target_pc = lookup_branch_target_pc;

    if (lookup_branch_target_present) begin
      unique case (lookup_branch_target_kind)
        TARGET_KIND_CONDITIONAL_BRANCH: predicted_taken = conditional_branch_predicted_taken;

        TARGET_KIND_DIRECT_JUMP, TARGET_KIND_INDIRECT_JUMP: predicted_taken = 1'b1;

        TARGET_KIND_RETURN: begin
          predicted_taken = 1'b1;
          if (lookup_query_q.return_target_present) begin
            predicted_target_pc = lookup_query_q.return_target_pc;
          end
        end

        default: ;
      endcase
    end

    // 当前不支持C扩展，错误的2字节对齐目标不能作为有效预测送入前端。
    if (predicted_target_pc[1:0] != 2'b00) begin
      predicted_taken = 1'b0;
    end

    lookup_prediction                  = '0;
    lookup_prediction.predicted_taken  = predicted_taken;
    lookup_prediction.predicted_target = predicted_taken ? predicted_target_pc : '0;
    lookup_next_pc                     = predicted_taken ?
                                         predicted_target_pc :
                                         lookup_query_q.pc +
                                         program_counter_t'(INSTRUCTION_BYTES);
  end

  // 第一级在请求握手时读取所选BTB ways、BHT计数器和RAS栈顶快照。第二级在能够
  // 前推时寄存比较结果。非阻塞赋值保证同一时钟沿先用旧查询产生响应，再装入新查询。
  // flush同时清空两级在途预测，但不清除BTB/BHT/RAS训练状态。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      lookup_query_q            <= '0;
      lookup_response_q         <= '0;
      lookup_query_present_q    <= 1'b0;
      lookup_response_present_q <= 1'b0;
    end else if (flush_lookup_i) begin
      lookup_query_present_q    <= 1'b0;
      lookup_response_present_q <= 1'b0;
    end else begin
      if (lookup_response_stage_ready) begin
        lookup_response_present_q <= lookup_query_present_q;
        if (lookup_query_present_q) begin
          lookup_response_q.pc         <= lookup_query_q.pc;
          lookup_response_q.epoch      <= lookup_query_q.epoch;
          lookup_response_q.prediction <= lookup_prediction;
          lookup_response_q.next_pc    <= lookup_next_pc;
        end
      end

      if (lookup_query_stage_ready) begin
        lookup_query_present_q <= lookup_request_valid_i;
        if (lookup_request_valid_i) begin
          lookup_query_q.pc                     <= lookup_request_pc_i;
          lookup_query_q.epoch                  <= lookup_request_epoch_i;
          lookup_query_q.branch_history_counter <=
              branch_history_lookup_counter;
          lookup_query_q.return_target_present  <= return_target_present;
          lookup_query_q.return_target_pc       <= return_target_pc;
        end
      end
    end
  end

  // 共享训练边界不改变精确控制流恢复的时刻。invalidate丢弃新训练事件；
  // BTB/RAS清除各自待更新状态，BHT仍可在该沿完成此前寄存的更新。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      resolved_control_flow_update_q <= '0;
    end else if (invalidate_i) begin
      resolved_control_flow_update_q <= '0;
    end else begin
      resolved_control_flow_update_q.present   <= resolved_control_flow_occurred_i;
      resolved_control_flow_update_q.pc        <= resolved_control_flow_pc_i;
      resolved_control_flow_update_q.target_pc <= resolved_control_flow_target_i;
      resolved_control_flow_update_q.immediate <= resolved_control_flow_imm_i;
      resolved_control_flow_update_q.op        <= resolved_control_flow_op_i;
      resolved_control_flow_update_q.rs1       <= resolved_control_flow_rs1_i;
      resolved_control_flow_update_q.rd        <= resolved_control_flow_rd_i;
      resolved_control_flow_update_q.taken     <= resolved_control_flow_taken_i;
    end
  end

`ifndef SYNTHESIS
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (lookup_response_valid_o && lookup_prediction_o.predicted_taken) |->
      (lookup_next_pc_o == lookup_prediction_o.predicted_target &&
       (lookup_next_pc_o[1:0] == 2'b00)))
  else $error("fetch predictor emitted an invalid taken prediction");

  // 普通反压必须保持响应；显式flush则取消旧epoch事务，下一拍允许撤销valid。
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (lookup_response_valid_o && !lookup_response_ready_i && !flush_lookup_i)
    |=> (flush_lookup_i ||
         (lookup_response_valid_o && $stable(lookup_prediction_o) &&
          $stable(lookup_next_pc_o))))
  else $error("fetch predictor changed its response while backpressured");
`endif
endmodule
