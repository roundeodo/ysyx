// 非推测 RAS：已寄存的解析事件直接更新地址数组和指针。
// 查询组合读取当前栈顶；不额外保存一份栈顶地址。
module riscv32_ras
  import riscv32_pkg::*;
#(
    parameter int unsigned RAS_ENTRY_COUNT = riscv_config_pkg::RETURN_STACK_ENTRY_COUNT
) (
    input  logic             clk_i,
    input  logic             rst_ni,
    output logic             lookup_target_present_o,
    output program_counter_t lookup_target_pc_o,

    input program_counter_t resolved_control_flow_pc_i,
    input xlen_data_t       resolved_control_flow_imm_i,
    input control_flow_op_e resolved_control_flow_op_i,
    input arch_reg_idx_t    resolved_control_flow_rs1_i,
    input arch_reg_idx_t    resolved_control_flow_rd_i,
    input logic             resolved_control_flow_event_i,
    input logic             resolved_control_flow_taken_i,
    input logic             invalidate_i
);
  localparam int unsigned INDEX_BITS = $clog2(RAS_ENTRY_COUNT);
  localparam int unsigned COUNT_BITS = $clog2(RAS_ENTRY_COUNT + 1);
  typedef logic [INDEX_BITS-1:0] stack_index_t;
  typedef logic [COUNT_BITS-1:0] stack_count_t;

  initial begin
    if (RAS_ENTRY_COUNT < 2 || (RAS_ENTRY_COUNT & (RAS_ENTRY_COUNT - 1)) != 0)
      $fatal(1, "RAS entries must be a power of two and at least 2");
  end

  // 1. 解析入口：rd/rs1 提示组合译为本沿的栈操作。
  typedef enum logic [1:0] {
    STACK_NONE,
    STACK_PUSH,
    STACK_POP,
    STACK_POP_PUSH
  } stack_op_e;
  stack_op_e operation;
  program_counter_t return_pc;
  assign return_pc = resolved_control_flow_pc_i + program_counter_t'(INSTRUCTION_BYTES);
  logic             rd_is_link;
  logic             rs1_is_link;
  logic             push_requested;
  logic             pop_requested;
  logic             resolved_jump_valid;

  assign rd_is_link =
      (resolved_control_flow_rd_i == arch_reg_idx_t'(1)) ||
      (resolved_control_flow_rd_i == arch_reg_idx_t'(5));
  assign rs1_is_link =
      (resolved_control_flow_rs1_i == arch_reg_idx_t'(1)) ||
      (resolved_control_flow_rs1_i == arch_reg_idx_t'(5));
  assign resolved_jump_valid = resolved_control_flow_event_i && resolved_control_flow_taken_i;
  assign push_requested      =
      resolved_jump_valid && rd_is_link &&
      ((resolved_control_flow_op_i == CF_JAL) || (resolved_control_flow_op_i == CF_JALR));
  assign pop_requested =
      resolved_jump_valid && (resolved_control_flow_op_i == CF_JALR) && rs1_is_link &&
      (!rd_is_link || resolved_control_flow_rd_i != resolved_control_flow_rs1_i) &&
      (resolved_control_flow_imm_i == '0);

  always_comb begin
    operation = STACK_NONE;
    if (!invalidate_i) begin
      unique case ({pop_requested, push_requested})
        2'b01:   operation = STACK_PUSH;
        2'b10:   operation = STACK_POP;
        2'b11:   operation = STACK_POP_PUSH;
        default: ;
      endcase
    end
  end

  // 2. 栈读口：write_index 指向下一次 push 的位置，减一即当前栈顶。
  // 容量为二的幂，定宽加减自动环绕，不再增加边界比较与额外 mux。
  program_counter_t address_array_q[RAS_ENTRY_COUNT];
  stack_index_t write_index_q, write_index_d;
  stack_count_t entry_count_q, entry_count_d;
  stack_index_t top_index;
  logic         array_write_enable;
  stack_index_t array_write_index;

  assign top_index               = write_index_q - stack_index_t'(1);
  assign lookup_target_present_o = entry_count_q != '0;
  assign lookup_target_pc_o      = lookup_target_present_o ? address_array_q[top_index] : '0;

  // 3. 栈操作输出：只决定本沿是否写地址数组及写入位置。
  always_comb begin
    array_write_enable = 1'b0;
    array_write_index  = write_index_q;
    unique case (operation)
      STACK_PUSH: array_write_enable = 1'b1;
      STACK_POP_PUSH: begin
        array_write_enable = 1'b1;
        if (entry_count_q != '0)
          array_write_index = top_index;
      end
      default: ;
    endcase
    if (invalidate_i)
      array_write_enable = 1'b0;
  end

  // 4. 指针和数量下一值：满栈 push 覆盖最旧项；空栈 pop 无动作。
  always_comb begin
    write_index_d = write_index_q;
    entry_count_d = entry_count_q;
    unique case (operation)
      STACK_PUSH: begin
        write_index_d = write_index_q + stack_index_t'(1);
        if (entry_count_q != stack_count_t'(RAS_ENTRY_COUNT))
          entry_count_d = entry_count_q + stack_count_t'(1);
      end
      STACK_POP: begin
        if (entry_count_q != '0) begin
          write_index_d = top_index;
          entry_count_d = entry_count_q - stack_count_t'(1);
        end
      end
      STACK_POP_PUSH: begin
        if (entry_count_q == '0) begin
          write_index_d = write_index_q + stack_index_t'(1);
          entry_count_d = stack_count_t'(1);
        end
      end
      default: ;
    endcase
    if (invalidate_i) begin
      write_index_d = '0;
      entry_count_d = '0;
    end
  end

  // 5. 栈状态更新：只复位指针与数量，无效地址数据不需要清零。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      write_index_q <= '0;
      entry_count_q <= '0;
    end else begin
      write_index_q <= write_index_d;
      entry_count_q <= entry_count_d;
    end
  end

  always_ff @(posedge clk_i) begin
    if (array_write_enable)
      address_array_q[array_write_index] <= return_pc;
  end

`ifndef SYNTHESIS
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    entry_count_q <= stack_count_t'(RAS_ENTRY_COUNT))
  else $error("RAS occupancy exceeded its capacity");
`endif
endmodule
