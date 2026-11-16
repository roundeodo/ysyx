// 分支条件与完整目标计算；预测比较仍由 EX 结果寄存级负责。
module riscv_branch_unit
  import riscv_pkg::*;
(
    input  branch_uop_ctrl_t operation_i,
    input  program_counter_t instruction_pc_i,
    input  xlen_data_t       operand_a_i,
    input  xlen_data_t       operand_b_i,
    input  xlen_data_t       immediate_i,
    output program_counter_t sequential_pc_o,
    output program_counter_t target_pc_o,
    output program_counter_t next_pc_o,
    output logic             target_misaligned_o
);
  logic condition_met;
  logic branch_taken;
  always_comb begin
    condition_met = 1'b0;
    unique case (operation_i.condition)
      BR_BEQ:
        condition_met = operand_a_i == operand_b_i;
      BR_BNE:
        condition_met = operand_a_i != operand_b_i;
      BR_BLT:
        condition_met = $signed(operand_a_i) < $signed(operand_b_i);
      BR_BGE:
        condition_met = $signed(operand_a_i) >= $signed(operand_b_i);
      BR_BLTU:
        condition_met = operand_a_i < operand_b_i;
      BR_BGEU:
        condition_met = operand_a_i >= operand_b_i;
      default: ;
    endcase
  end
  always_comb begin
    branch_taken = 1'b0;
    target_pc_o  = '0;
    unique case (operation_i.op)
      CF_BRANCH, CF_JAL: begin
        branch_taken = operation_i.op == CF_JAL || condition_met;
        target_pc_o  = instruction_pc_i + immediate_i;
      end
      CF_JALR: begin
        branch_taken   = 1'b1;
        target_pc_o    = operand_a_i + immediate_i;
        target_pc_o[0] = 1'b0;
      end
      default: ;
    endcase
  end
  assign sequential_pc_o     = instruction_pc_i + program_counter_t'(INSTRUCTION_BYTES);
  assign next_pc_o           = branch_taken ? target_pc_o : sequential_pc_o;
  // 当前没有 C 扩展；先应用 JALR bit 0 清零，再检查四字节对齐。
  assign target_misaligned_o = branch_taken && target_pc_o[1:0] != 2'b00;
endmodule
