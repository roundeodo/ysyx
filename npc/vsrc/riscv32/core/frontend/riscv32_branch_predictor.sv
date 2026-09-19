// 单级取指预测：并行查 BHT/BTB/RAS，选择结果后写入一个响应寄存器。
// 训练与查询并行：源码先列训练入口，再列共享表、查询选择和响应寄存器。
module riscv32_branch_predictor
  import riscv32_pkg::*;
#(
    parameter int unsigned BHT_ENTRY_COUNT = riscv_config_pkg::BRANCH_HISTORY_ENTRY_COUNT,
    parameter int unsigned BTB_ENTRY_COUNT = riscv_config_pkg::BRANCH_TARGET_ENTRY_COUNT,
    parameter int unsigned BTB_WAY_COUNT   = riscv_config_pkg::BRANCH_TARGET_WAY_COUNT,
    parameter int unsigned RAS_ENTRY_COUNT = riscv_config_pkg::RETURN_STACK_ENTRY_COUNT
) (
    input logic clk_i,
    input logic rst_ni,

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

    input program_counter_t resolved_control_flow_pc_i,
    input program_counter_t resolved_control_flow_target_i,
    input xlen_data_t       resolved_control_flow_imm_i,
    input control_flow_op_e resolved_control_flow_op_i,
    input arch_reg_idx_t    resolved_control_flow_rs1_i,
    input arch_reg_idx_t    resolved_control_flow_rd_i,
    input logic             resolved_control_flow_event_i,
    input logic             resolved_control_flow_taken_i,

    // redirect只清除当前查询流水，不清除训练状态；fence.i才清除可能过期的BTB内容。
    input logic flush_lookup_i,
    input logic invalidate_i
);

  // 1. 训练入口：只保存 BHT/BTB 写表需要的信息。
  typedef struct packed {
    program_counter_t    pc;
    program_counter_t    target_pc;
    branch_target_kind_e kind;
    logic                taken;
  } training_entry_t;

  training_entry_t training_q, training_d;
  logic training_present_q, training_present_d;
  logic resolved_rd_is_link;
  logic resolved_rs1_is_link;
  logic resolved_is_return;

  assign resolved_rd_is_link =
      (resolved_control_flow_rd_i == arch_reg_idx_t'(1)) ||
      (resolved_control_flow_rd_i == arch_reg_idx_t'(5));
  assign resolved_rs1_is_link =
      (resolved_control_flow_rs1_i == arch_reg_idx_t'(1)) ||
      (resolved_control_flow_rs1_i == arch_reg_idx_t'(5));
  assign resolved_is_return =
      (resolved_control_flow_op_i == CF_JALR) && resolved_rs1_is_link &&
      (!resolved_rd_is_link ||
       (resolved_control_flow_rd_i != resolved_control_flow_rs1_i)) &&
      (resolved_control_flow_imm_i == '0);

  always_comb begin
    training_d         = training_q;
    training_present_d = resolved_control_flow_event_i && !invalidate_i;
    if (resolved_control_flow_event_i) begin
      training_d.pc        = resolved_control_flow_pc_i;
      training_d.target_pc = resolved_control_flow_target_i;
      training_d.taken     = resolved_control_flow_taken_i;
      training_d.kind      = TARGET_KIND_CONDITIONAL_BRANCH;
      unique case (resolved_control_flow_op_i)
        CF_JAL:
          training_d.kind = TARGET_KIND_DIRECT_JUMP;
        CF_JALR:
          training_d.kind = resolved_is_return ? TARGET_KIND_RETURN : TARGET_KIND_INDIRECT_JUMP;
        default: ;
      endcase
    end
  end

  always_ff @(posedge clk_i) begin
    training_q <= training_d;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)
      training_present_q <= 1'b0;
    else
      training_present_q <= training_present_d;
  end

  // 2. 并行查表：三个单元都读取当前请求，没有各自的查询流水或握手状态。
  logic [1:0]          history_counter;
  logic                target_present;
  program_counter_t    target_pc;
  branch_target_kind_e target_kind;
  logic                return_present;
  program_counter_t    return_pc;

  riscv32_bht #(
      .BHT_ENTRY_COUNT(BHT_ENTRY_COUNT)
  ) u_bht (
      .clk_i            (clk_i),
      .rst_ni           (rst_ni),
      .lookup_pc_i      (lookup_request_pc_i),
      .lookup_counter_o (history_counter),
      .training_pc_i    (training_q.pc),
      .training_valid_i (training_present_q && (training_q.kind == TARGET_KIND_CONDITIONAL_BRANCH)),
      .training_taken_i (training_q.taken)
  );

  riscv32_btb #(
      .BTB_ENTRY_COUNT (BTB_ENTRY_COUNT),
      .BTB_WAY_COUNT   (BTB_WAY_COUNT)
  ) u_btb (
      .clk_i                   (clk_i),
      .rst_ni                  (rst_ni),
      .lookup_pc_i             (lookup_request_pc_i),
      .lookup_target_present_o (target_present),
      .lookup_target_pc_o      (target_pc),
      .lookup_target_kind_o    (target_kind),
      .training_pc_i           (training_q.pc),
      .training_target_pc_i    (training_q.target_pc),
      .training_kind_i         (training_q.kind),
      .training_valid_i        (training_present_q),
      .invalidate_i            (invalidate_i)
  );

  riscv32_ras #(
      .RAS_ENTRY_COUNT(RAS_ENTRY_COUNT)
  ) u_ras (
      .clk_i                         (clk_i),
      .rst_ni                        (rst_ni),
      .lookup_target_present_o       (return_present),
      .lookup_target_pc_o            (return_pc),
      .resolved_control_flow_pc_i    (resolved_control_flow_pc_i),
      .resolved_control_flow_imm_i   (resolved_control_flow_imm_i),
      .resolved_control_flow_op_i    (resolved_control_flow_op_i),
      .resolved_control_flow_rs1_i   (resolved_control_flow_rs1_i),
      .resolved_control_flow_rd_i    (resolved_control_flow_rd_i),
      .resolved_control_flow_event_i (resolved_control_flow_event_i),
      .resolved_control_flow_taken_i (resolved_control_flow_taken_i),
      .invalidate_i                  (invalidate_i)
  );

  // 3. 预测选择：BTB 决定指令种类，BHT 决定条件分支方向，RAS 提供返回目标。
  branch_prediction_t selected_prediction;
  program_counter_t   selected_target_pc;
  logic               selected_taken;

  always_comb begin
    selected_taken     = 1'b0;
    selected_target_pc = target_pc;
    if (target_present) begin
      unique case (target_kind)
        TARGET_KIND_CONDITIONAL_BRANCH:
          selected_taken = history_counter[1];
        TARGET_KIND_DIRECT_JUMP, TARGET_KIND_INDIRECT_JUMP:
          selected_taken = 1'b1;
        TARGET_KIND_RETURN: begin
          selected_taken = 1'b1;
          if (return_present)
            selected_target_pc = return_pc;
        end
        default: ;
      endcase
    end
    // 本核没有 C 扩展，预测目标必须四字节对齐。
    if (selected_target_pc[1:0] != 2'b00)
      selected_taken = 1'b0;
    selected_prediction                  = '0;
    selected_prediction.predicted_taken  = selected_taken;
    selected_prediction.predicted_target = selected_taken ? selected_target_pc : '0;
  end

  // 4. 唯一查询寄存级：完整响应在反压时保持，消费旧响应的同沿可接收新请求。
  typedef struct packed {
    program_counter_t   pc;
    fetch_epoch_t       epoch;
    branch_prediction_t prediction;
  } response_t;

  response_t response_q, response_d;
  logic response_present_q, response_present_d;
  logic request_handshake;

  assign lookup_response_pc_o    = response_q.pc;
  assign lookup_response_epoch_o = response_q.epoch;
  assign lookup_prediction_o     = response_q.prediction;
  assign lookup_response_valid_o = response_present_q;
  assign lookup_next_pc_o        =
      response_q.prediction.predicted_taken ? response_q.prediction.predicted_target :
      response_q.pc + program_counter_t'(INSTRUCTION_BYTES);
  assign lookup_request_ready_o =
      (!response_present_q || lookup_response_ready_i) && !flush_lookup_i;
  assign request_handshake = lookup_request_valid_i && lookup_request_ready_o;

  always_comb begin
    response_d         = response_q;
    response_present_d = response_present_q;
    if (lookup_response_ready_i)
      response_present_d = 1'b0;
    if (request_handshake) begin
      response_d.pc         = lookup_request_pc_i;
      response_d.epoch      = lookup_request_epoch_i;
      response_d.prediction = selected_prediction;
      response_present_d    = 1'b1;
    end
    if (flush_lookup_i)
      response_present_d = 1'b0;
  end

  always_ff @(posedge clk_i) begin
    response_q <= response_d;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)
      response_present_q <= 1'b0;
    else
      response_present_q <= response_present_d;
  end

`ifndef SYNTHESIS
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (lookup_response_valid_o && lookup_prediction_o.predicted_taken) |->
      (lookup_next_pc_o == lookup_prediction_o.predicted_target &&
       lookup_next_pc_o[1:0] == 2'b00))
  else $error("fetch predictor emitted an invalid taken prediction");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (lookup_response_valid_o && !lookup_response_ready_i && !flush_lookup_i)
    |=> (flush_lookup_i || (lookup_response_valid_o && $stable(response_q))))
  else $error("fetch predictor changed a stalled response");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    request_handshake |=> lookup_response_valid_o)
  else $error("fetch predictor did not return a query in one stage");
`endif
endmodule
