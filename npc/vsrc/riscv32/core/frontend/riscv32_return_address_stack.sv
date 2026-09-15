// 返回地址栈：按已解析控制流更新，不进行推测push/pop。
// 栈顶组合输出由父模块在查询握手沿保存，训练操作与共享解析事件并行寄存。
module riscv32_return_address_stack
  import riscv32_pkg::*;
#(
    parameter int unsigned RAS_ENTRY_COUNT = riscv_config_pkg::RETURN_STACK_ENTRY_COUNT
) (
    input  logic             clk_i,
    input  logic             rst_ni,
    output logic             lookup_target_present_o,
    output program_counter_t lookup_target_pc_o,

    input  program_counter_t resolved_control_flow_pc_i,
    input  xlen_data_t       resolved_control_flow_imm_i,
    input  control_flow_op_e resolved_control_flow_op_i,
    input  arch_reg_idx_t    resolved_control_flow_rs1_i,
    input  arch_reg_idx_t    resolved_control_flow_rd_i,
    input  logic             resolved_control_flow_occurred_i,
    input  logic             resolved_control_flow_taken_i,
    input  logic             invalidate_i
);
  localparam int unsigned RETURN_STACK_INDEX_WIDTH = $clog2(RAS_ENTRY_COUNT);
  localparam int unsigned RETURN_STACK_COUNT_WIDTH = $clog2(RAS_ENTRY_COUNT + 1);
  typedef logic [RETURN_STACK_INDEX_WIDTH-1:0] return_stack_index_t;
  typedef logic [RETURN_STACK_COUNT_WIDTH-1:0] return_stack_count_t;

  typedef enum logic [1:0] {
    RETURN_STACK_UPDATE_NONE,
    RETURN_STACK_UPDATE_PUSH,
    RETURN_STACK_UPDATE_POP,
    RETURN_STACK_UPDATE_POP_PUSH
  } return_stack_update_op_e;

  // 先把RISC-V的rd/rs1/op提示译成简单的RAS微操作，再驱动RAS数组写口。
  // 这样复杂的call/return识别不会直接落到每个RAS数据寄存器的D端。
  typedef struct packed {
    return_stack_update_op_e op;
    program_counter_t        return_pc;
  } return_stack_update_t;

  program_counter_t    return_stack_pc_array_q[RAS_ENTRY_COUNT];
  return_stack_index_t return_stack_write_index_q;
  return_stack_index_t return_stack_top_index;
  return_stack_count_t return_stack_entry_count_q;
  program_counter_t    return_stack_top_pc_q;

  assign lookup_target_present_o = return_stack_entry_count_q != '0;
  assign lookup_target_pc_o      = return_stack_top_pc_q;
  assign return_stack_top_index = decrement_return_stack_index(return_stack_write_index_q);

  initial begin
    if ((RAS_ENTRY_COUNT < 2) || ((RAS_ENTRY_COUNT & (RAS_ENTRY_COUNT - 1)) != 0)) begin
      $fatal(1, "return stack entry count must be a power of two and at least 2");
    end
  end

  function automatic logic is_link_register(input arch_reg_idx_t register_index);
    return (register_index == arch_reg_idx_t'(1)) || (register_index == arch_reg_idx_t'(5));
  endfunction

  function automatic return_stack_index_t increment_return_stack_index(
      input return_stack_index_t current_index);
    return (current_index == return_stack_index_t'(RAS_ENTRY_COUNT - 1)) ?
           '0 : current_index + return_stack_index_t'(1);
  endfunction

  function automatic return_stack_index_t decrement_return_stack_index(
      input return_stack_index_t current_index);
    return (current_index == '0) ?
           return_stack_index_t'(RAS_ENTRY_COUNT - 1) :
           current_index - return_stack_index_t'(1);
  endfunction

  // 调用/返回提示只译成栈操作，随后一个寄存边界再更新栈状态。
  logic                 incoming_rd_is_link_register;
  logic                 incoming_rs1_is_link_register;
  logic                 incoming_return_instruction_present;
  logic                 incoming_return_stack_push;
  logic                 incoming_return_stack_pop;
  return_stack_update_t return_stack_update_d;
  return_stack_update_t return_stack_update_q;

  assign incoming_rd_is_link_register  = is_link_register(resolved_control_flow_rd_i);
  assign incoming_rs1_is_link_register = is_link_register(resolved_control_flow_rs1_i);
  assign incoming_return_instruction_present =
      (resolved_control_flow_op_i == CF_JALR) && incoming_rs1_is_link_register &&
      (!incoming_rd_is_link_register ||
       (resolved_control_flow_rd_i != resolved_control_flow_rs1_i)) &&
      (resolved_control_flow_imm_i == '0);
  assign incoming_return_stack_push = resolved_control_flow_occurred_i &&
      resolved_control_flow_taken_i && incoming_rd_is_link_register &&
      ((resolved_control_flow_op_i == CF_JAL) || (resolved_control_flow_op_i == CF_JALR));
  assign incoming_return_stack_pop = resolved_control_flow_occurred_i &&
      resolved_control_flow_taken_i && incoming_return_instruction_present;

  always_comb begin
    return_stack_update_d           = '0;
    return_stack_update_d.return_pc =
        resolved_control_flow_pc_i + program_counter_t'(INSTRUCTION_BYTES);

    unique case ({incoming_return_stack_pop, incoming_return_stack_push})
      2'b01: return_stack_update_d.op = RETURN_STACK_UPDATE_PUSH;
      2'b10: return_stack_update_d.op = RETURN_STACK_UPDATE_POP;
      2'b11: return_stack_update_d.op = RETURN_STACK_UPDATE_POP_PUSH;
      default: return_stack_update_d.op = RETURN_STACK_UPDATE_NONE;
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      return_stack_update_q <= '0;
    end else if (invalidate_i) begin
      return_stack_update_q <= '0;
    end else begin
      return_stack_update_q <= return_stack_update_d;
    end
  end

  // write_index指向下一次push位置，top位于write_index-1。更新使用已解析控制流，
  // 不需要为当前短流水线增加推测RAS checkpoint；未来扩大在途窗口时再引入恢复状态。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      return_stack_write_index_q <= '0;
      return_stack_entry_count_q <= '0;
      return_stack_top_pc_q      <= '0;
    end else if (invalidate_i) begin
      return_stack_write_index_q <= '0;
      return_stack_entry_count_q <= '0;
      return_stack_top_pc_q      <= '0;
    end else begin
      unique case (return_stack_update_q.op)
        RETURN_STACK_UPDATE_PUSH: begin
          return_stack_pc_array_q[return_stack_write_index_q] <=
              return_stack_update_q.return_pc;
          return_stack_write_index_q <=
              increment_return_stack_index(return_stack_write_index_q);
          return_stack_top_pc_q <= return_stack_update_q.return_pc;
          if (return_stack_entry_count_q != return_stack_count_t'(RAS_ENTRY_COUNT)) begin
            return_stack_entry_count_q <= return_stack_entry_count_q + return_stack_count_t'(1);
          end
        end

        RETURN_STACK_UPDATE_POP: begin
          if (return_stack_entry_count_q != '0) begin
            return_stack_write_index_q <= decrement_return_stack_index(return_stack_write_index_q);
            return_stack_entry_count_q <= return_stack_entry_count_q - return_stack_count_t'(1);
            if (return_stack_entry_count_q == return_stack_count_t'(1)) begin
              return_stack_top_pc_q <= '0;
            end else begin
              return_stack_top_pc_q <= return_stack_pc_array_q[
                  decrement_return_stack_index(decrement_return_stack_index(
                      return_stack_write_index_q
                  ))
              ];
            end
          end
        end

        RETURN_STACK_UPDATE_POP_PUSH: begin
          if (return_stack_entry_count_q != '0) begin
            return_stack_pc_array_q[return_stack_top_index] <=
                return_stack_update_q.return_pc;
            return_stack_top_pc_q <= return_stack_update_q.return_pc;
          end else begin
            return_stack_pc_array_q[return_stack_write_index_q] <=
                return_stack_update_q.return_pc;
            return_stack_write_index_q <=
              increment_return_stack_index(return_stack_write_index_q);
            return_stack_entry_count_q <= return_stack_count_t'(1);
            return_stack_top_pc_q <= return_stack_update_q.return_pc;
          end
        end

        default: ;
      endcase
    end
  end

`ifndef SYNTHESIS
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    return_stack_entry_count_q <= return_stack_count_t'(RAS_ENTRY_COUNT))
  else $error("return-address stack entry count exceeded its capacity");
`endif
endmodule
