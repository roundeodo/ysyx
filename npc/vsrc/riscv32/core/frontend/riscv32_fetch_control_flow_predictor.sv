// 取指响应处的低成本控制流预测器。
//
// 预测发生在指令进入fetch buffer之前，比ID/EX级恢复更早。JAL恒预测跳转；条件分支
// 使用16项、每项2 bit的饱和方向计数器；常规JALR仍由EX解析，ret使用4项返回地址栈
// 预测目标。EX独立计算真实后继PC并纠错，预测器只在控制流指令真正完成后更新状态。
module riscv32_fetch_control_flow_predictor
  import riscv32_pkg::*;
(
    input logic clk_i,
    input logic rst_ni,

    input fetch_entry_t fetch_entry_i,
    input logic         fetch_entry_handshake_occurred_i,

    input program_counter_t resolved_control_flow_pc_i,
    input control_flow_op_e resolved_control_flow_op_i,
    input arch_reg_idx_t    resolved_control_flow_rs1_i,
    input arch_reg_idx_t    resolved_control_flow_rd_i,
    input logic             resolved_control_flow_occurred_i,
    input logic             resolved_control_flow_taken_i,

    output fetch_entry_t predicted_fetch_entry_o,
    output redirect_req_t prediction_redirect_req_o,
    output logic          prediction_redirect_req_valid_o
);
  localparam int unsigned BRANCH_HISTORY_ENTRY_COUNT = 16;
  localparam int unsigned BRANCH_HISTORY_INDEX_WIDTH = $clog2(BRANCH_HISTORY_ENTRY_COUNT);
  // microbench控制流trace中RAS4与RAS8只相差250次预测错误；在当前标准单元映射下，
  // RAS8的256个数据位会实现为触发器和选择逻辑，面积收益比不合理，因此选择RAS4。
  // 该容量仍局限在预测器内部，将来替换成独立预测存储宏时不会改变前端接口。
  localparam int unsigned RETURN_STACK_ENTRY_COUNT   = 4;
  localparam int unsigned RETURN_STACK_INDEX_WIDTH   = $clog2(RETURN_STACK_ENTRY_COUNT);
  localparam int unsigned RETURN_STACK_COUNT_WIDTH   = $clog2(RETURN_STACK_ENTRY_COUNT + 1);

  logic [6:0]             instruction_opcode;
  logic [2:0]             branch_condition_encoding;
  logic                   legal_conditional_branch_present;
  logic                   direct_jump_present;
  logic                   indirect_jump_present;
  logic                   lookup_rd_is_link_register;
  logic                   lookup_rs1_is_link_register;
  logic                   return_instruction_present;
  logic [BRANCH_HISTORY_INDEX_WIDTH-1:0] lookup_branch_history_index;
  logic [BRANCH_HISTORY_INDEX_WIDTH-1:0] resolved_branch_history_index;
  logic [1:0]             branch_history_counter_array_q[BRANCH_HISTORY_ENTRY_COUNT];
  logic                   conditional_branch_predicted_taken;
  logic                   resolved_rd_is_link_register;
  logic                   resolved_rs1_is_link_register;
  logic                   resolved_return_stack_push;
  logic                   resolved_return_stack_pop;
  program_counter_t       return_stack_pc_array_q[RETURN_STACK_ENTRY_COUNT];
  logic [RETURN_STACK_INDEX_WIDTH-1:0] return_stack_write_index_q;
  logic [RETURN_STACK_INDEX_WIDTH-1:0] return_stack_top_index;
  logic [RETURN_STACK_COUNT_WIDTH-1:0] return_stack_entry_count_q;
  program_counter_t       return_stack_top_pc;
  logic                   return_prediction_available;
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
  assign indirect_jump_present = (instruction_opcode == OPCODE_JALR) &&
                                 (fetch_entry_i.instruction[14:12] == 3'b000);

  function automatic logic is_link_register(input arch_reg_idx_t register_index);
    return (register_index == arch_reg_idx_t'(1)) ||
           (register_index == arch_reg_idx_t'(5));
  endfunction

  function automatic logic [RETURN_STACK_INDEX_WIDTH-1:0] increment_return_stack_index(
      input logic [RETURN_STACK_INDEX_WIDTH-1:0] current_index
  );
    return (current_index == RETURN_STACK_INDEX_WIDTH'(RETURN_STACK_ENTRY_COUNT - 1)) ?
           '0 : current_index + RETURN_STACK_INDEX_WIDTH'(1);
  endfunction

  function automatic logic [RETURN_STACK_INDEX_WIDTH-1:0] decrement_return_stack_index(
      input logic [RETURN_STACK_INDEX_WIDTH-1:0] current_index
  );
    return (current_index == '0) ?
           RETURN_STACK_INDEX_WIDTH'(RETURN_STACK_ENTRY_COUNT - 1) :
           current_index - RETURN_STACK_INDEX_WIDTH'(1);
  endfunction

  assign lookup_rd_is_link_register =
      is_link_register(arch_reg_idx_t'(fetch_entry_i.instruction[11:7]));
  assign lookup_rs1_is_link_register =
      is_link_register(arch_reg_idx_t'(fetch_entry_i.instruction[19:15]));

  // 遵循RISC-V对JALR寄存器组合给出的RAS提示：rs1为x1/x5，并且rd不是同一个
  // link register时需要pop。常规ret(jalr x0, x1/x5, 0)属于该集合。
  assign return_instruction_present = indirect_jump_present &&
      lookup_rs1_is_link_register &&
      (!lookup_rd_is_link_register ||
       (fetch_entry_i.instruction[11:7] != fetch_entry_i.instruction[19:15]));
  assign return_stack_top_index = decrement_return_stack_index(return_stack_write_index_q);
  assign return_stack_top_pc = return_stack_pc_array_q[return_stack_top_index];
  assign return_prediction_available = return_instruction_present &&
                                       (return_stack_entry_count_q != '0);

  // 以4字节指令地址为单位索引方向表。这里只预测方向，跳转目标仍由当前B/J型立即数
  // 直接形成，因此不需要为条件分支额外保存BTB tag和target。
  assign lookup_branch_history_index =
      fetch_entry_i.pc[BRANCH_HISTORY_INDEX_WIDTH+1:2];
  assign resolved_branch_history_index =
      resolved_control_flow_pc_i[BRANCH_HISTORY_INDEX_WIDTH+1:2];
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
    end else if (resolved_control_flow_occurred_i &&
                 (resolved_control_flow_op_i == CF_BRANCH)) begin
      branch_history_counter_array_q[resolved_branch_history_index] <=
          update_branch_history_counter(
              branch_history_counter_array_q[resolved_branch_history_index],
              resolved_control_flow_taken_i
          );
    end
  end

  assign resolved_rd_is_link_register = is_link_register(resolved_control_flow_rd_i);
  assign resolved_rs1_is_link_register = is_link_register(resolved_control_flow_rs1_i);
  assign resolved_return_stack_push = resolved_control_flow_occurred_i &&
      resolved_control_flow_taken_i &&
      (((resolved_control_flow_op_i == CF_JAL) && resolved_rd_is_link_register) ||
       ((resolved_control_flow_op_i == CF_JALR) && resolved_rd_is_link_register));
  assign resolved_return_stack_pop = resolved_control_flow_occurred_i &&
      resolved_control_flow_taken_i && (resolved_control_flow_op_i == CF_JALR) &&
      resolved_rs1_is_link_register &&
      (!resolved_rd_is_link_register ||
       (resolved_control_flow_rd_i != resolved_control_flow_rs1_i));

  // write_index指向下一次push位置，top位于write_index-1。只复位索引和有效项数，
  // 不复位数据阵列；entry_count为0时旧数据不可见，避免为256个数据位增加复位网络。
  // pop+push用于协程式JALR：新返回地址直接替换旧栈顶，深度保持不变。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      return_stack_write_index_q <= '0;
      return_stack_entry_count_q <= '0;
    end else begin
      unique case ({resolved_return_stack_pop, resolved_return_stack_push})
        2'b01: begin
          return_stack_pc_array_q[return_stack_write_index_q] <=
              resolved_control_flow_pc_i + program_counter_t'(INSTRUCTION_BYTES);
          return_stack_write_index_q <=
              increment_return_stack_index(return_stack_write_index_q);
          if (return_stack_entry_count_q != RETURN_STACK_COUNT_WIDTH'(RETURN_STACK_ENTRY_COUNT)) begin
            return_stack_entry_count_q <= return_stack_entry_count_q + RETURN_STACK_COUNT_WIDTH'(1);
          end
        end

        2'b10: begin
          if (return_stack_entry_count_q != '0) begin
            return_stack_write_index_q <=
                decrement_return_stack_index(return_stack_write_index_q);
            return_stack_entry_count_q <= return_stack_entry_count_q - RETURN_STACK_COUNT_WIDTH'(1);
          end
        end

        2'b11: begin
          if (return_stack_entry_count_q != '0) begin
            return_stack_pc_array_q[return_stack_top_index] <=
                resolved_control_flow_pc_i + program_counter_t'(INSTRUCTION_BYTES);
          end else begin
            return_stack_pc_array_q[return_stack_write_index_q] <=
                resolved_control_flow_pc_i + program_counter_t'(INSTRUCTION_BYTES);
            return_stack_write_index_q <=
                increment_return_stack_index(return_stack_write_index_q);
            return_stack_entry_count_q <= RETURN_STACK_COUNT_WIDTH'(1);
          end
        end

        default: ;
      endcase
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

  assign predicted_target_pc = return_prediction_available ?
                               return_stack_top_pc :
                               fetch_entry_i.pc + program_counter_t'(control_flow_immediate);
  assign predicted_target_aligned = predicted_target_pc[1:0] == 2'b00;
  assign predicted_taken = !fetch_entry_i.exception_valid && predicted_target_aligned &&
                           (return_prediction_available || direct_jump_present ||
                            (legal_conditional_branch_present &&
                             conditional_branch_predicted_taken));

  always_comb begin
    predicted_fetch_entry_o                             = fetch_entry_i;
    predicted_fetch_entry_o.prediction                  = '0;
    predicted_fetch_entry_o.prediction.predicted_taken  = predicted_taken;
    // B/J目标可由EX重新计算，不需要逐级携带；RAS目标来自动态调用历史，必须随ret
    // 保存到EX，才能检查预测方向正确但目标错误的情况。
    predicted_fetch_entry_o.prediction.predicted_target =
        return_prediction_available ? return_stack_top_pc : '0;

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

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    return_stack_entry_count_q <= RETURN_STACK_COUNT_WIDTH'(RETURN_STACK_ENTRY_COUNT))
  else $error("return-address stack entry count exceeded its capacity");
`endif

endmodule
