// 取指响应处的低成本控制流预测器。
//
// 预测发生在指令进入fetch buffer之前，比ID/EX级恢复更早。JAL恒预测跳转；条件分支
// 使用16项、每项2 bit的饱和方向计数器；JALR留给后续BTB/RAS或EX级解析。EX仍会
// 独立计算真实后继PC、纠正错误预测，并用已解析条件分支训练方向表。
module riscv32_fetch_control_flow_predictor
  import riscv32_pkg::*;
(
    input logic clk_i,
    input logic rst_ni,

    input fetch_entry_t fetch_entry_i,
    input logic         fetch_entry_handshake_occurred_i,

    input program_counter_t resolved_conditional_branch_pc_i,
    input logic             resolved_conditional_branch_occurred_i,
    input logic             resolved_conditional_branch_taken_i,

    output fetch_entry_t predicted_fetch_entry_o,
    output redirect_req_t prediction_redirect_req_o,
    output logic          prediction_redirect_req_valid_o
);
  localparam int unsigned BRANCH_HISTORY_ENTRY_COUNT = 16;
  localparam int unsigned BRANCH_HISTORY_INDEX_WIDTH = $clog2(BRANCH_HISTORY_ENTRY_COUNT);

  logic [6:0]             instruction_opcode;
  logic [2:0]             branch_condition_encoding;
  logic                   legal_conditional_branch_present;
  logic                   direct_jump_present;
  logic [BRANCH_HISTORY_INDEX_WIDTH-1:0] lookup_branch_history_index;
  logic [BRANCH_HISTORY_INDEX_WIDTH-1:0] resolved_branch_history_index;
  logic [1:0]             branch_history_counter_array_q[BRANCH_HISTORY_ENTRY_COUNT];
  logic                   conditional_branch_predicted_taken;
  logic                   predicted_taken;
  xlen_data_t             control_flow_immediate;
  program_counter_t       predicted_target_pc;
  logic                   predicted_target_aligned;

  assign instruction_opcode       = fetch_entry_i.instruction[6:0];
  assign branch_condition_encoding = fetch_entry_i.instruction[14:12];

  // RV32I/RV64I条件分支只定义000、001、100、101、110和111六种funct3。
  // 在完整IDU译码前先过滤保留编码，避免非法指令错误地改变取指方向。
  always_comb begin
    unique case (branch_condition_encoding)
      3'b000, 3'b001, 3'b100, 3'b101, 3'b110, 3'b111:
        legal_conditional_branch_present = instruction_opcode == OPCODE_BRANCH;
      default: legal_conditional_branch_present = 1'b0;
    endcase
  end

  assign direct_jump_present = instruction_opcode == OPCODE_JAL;

  // 以4字节指令地址为单位索引方向表。这里只预测方向，跳转目标仍由当前B/J型立即数
  // 直接形成，因此不需要为条件分支额外保存BTB tag和target。
  assign lookup_branch_history_index =
      fetch_entry_i.pc[BRANCH_HISTORY_INDEX_WIDTH+1:2];
  assign resolved_branch_history_index =
      resolved_conditional_branch_pc_i[BRANCH_HISTORY_INDEX_WIDTH+1:2];
  assign conditional_branch_predicted_taken =
      branch_history_counter_array_q[lookup_branch_history_index][1];

  function automatic logic [1:0] update_branch_history_counter(
      input logic [1:0] current_counter,
      input logic       branch_taken
  );
    if (branch_taken) begin
      return (current_counter == 2'b11) ? current_counter : current_counter + 2'b01;
    end
    return (current_counter == 2'b00) ? current_counter : current_counter - 2'b01;
  endfunction

  // 00/01预测不跳，10/11预测跳转。复位到弱不跳转，使尚未执行过的分支不会因为
  // 同一索引上的未知历史直接跳向错误目标。训练只使用EX级实际完成的条件分支。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for (int unsigned entry = 0; entry < BRANCH_HISTORY_ENTRY_COUNT; entry++) begin
        branch_history_counter_array_q[entry] <= 2'b01;
      end
    end else if (resolved_conditional_branch_occurred_i) begin
      branch_history_counter_array_q[resolved_branch_history_index] <=
          update_branch_history_counter(
              branch_history_counter_array_q[resolved_branch_history_index],
              resolved_conditional_branch_taken_i
          );
    end
  end

  // B型立即数：imm[12|10:5|4:1|11|0]，最低位由ISA固定为0。
  // J型立即数：imm[20|10:1|11|19:12|0]。先符号扩展到XLEN，再与PC相加。
  always_comb begin
    control_flow_immediate = '0;
    if (legal_conditional_branch_present) begin
      control_flow_immediate = {{(XLEN-13){fetch_entry_i.instruction[31]}},
                                fetch_entry_i.instruction[31],
                                fetch_entry_i.instruction[7],
                                fetch_entry_i.instruction[30:25],
                                fetch_entry_i.instruction[11:8], 1'b0};
    end else if (direct_jump_present) begin
      control_flow_immediate = {{(XLEN-21){fetch_entry_i.instruction[31]}},
                                fetch_entry_i.instruction[31],
                                fetch_entry_i.instruction[19:12],
                                fetch_entry_i.instruction[20],
                                fetch_entry_i.instruction[30:21], 1'b0};
    end
  end

  assign predicted_target_pc = fetch_entry_i.pc + program_counter_t'(control_flow_immediate);
  assign predicted_target_aligned = predicted_target_pc[1:0] == 2'b00;
  assign predicted_taken = !fetch_entry_i.exception_valid && predicted_target_aligned &&
                           (direct_jump_present ||
                            (legal_conditional_branch_present &&
                             conditional_branch_predicted_taken));

  always_comb begin
    predicted_fetch_entry_o                             = fetch_entry_i;
    predicted_fetch_entry_o.prediction                  = '0;
    predicted_fetch_entry_o.prediction.predicted_taken  = predicted_taken;
    predicted_fetch_entry_o.prediction.predicted_target = predicted_taken ?
                                                                  predicted_target_pc :
                                                                  fetch_entry_i.pc +
                                                                  program_counter_t'(INSTRUCTION_BYTES);

    prediction_redirect_req_o                 = '0;
    prediction_redirect_req_o.target_pc       = predicted_target_pc;
    prediction_redirect_req_o.source_pc       = fetch_entry_i.pc;
    prediction_redirect_req_o.reason          = REDIRECT_FETCH_PREDICTION;
    prediction_redirect_req_o.flush_inclusive = 1'b0;

    // 只有fetch entry真正进入队列时，预测才能改变后续PC。反压期间prediction payload
    // 保持组合稳定，但不会重复发出重定向事件。
    prediction_redirect_req_valid_o = fetch_entry_handshake_occurred_i && predicted_taken;
  end

`ifndef SYNTHESIS
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    prediction_redirect_req_valid_o |->
      (predicted_fetch_entry_o.prediction.predicted_taken &&
       (prediction_redirect_req_o.target_pc[1:0] == 2'b00)))
  else $error("fetch predictor emitted an invalid taken prediction");
`endif

endmodule
