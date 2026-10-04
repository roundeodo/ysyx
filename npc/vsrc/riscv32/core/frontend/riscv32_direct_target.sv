// 当前指令已由I-cache返回：精确计算B/J目标；JALR仍交给现有预测/EX路径。
module riscv32_direct_target (
    input  logic [31:0] pc_i,
    input  logic [31:0] instruction_i,
    input  logic [ 1:0] direction_counter_i,
    output logic        known_o,
    output logic        taken_o,
    output logic [31:0] target_o
);
  logic conditional_branch, jal_instruction;
  logic [31:0] branch_displacement;
  logic        conditional_taken;

  // 真实指令类型/立即数译码 → 目标加法与方向选择 → 输出。
  // 条件真假仍由EX确认，这里不读取GPR，也不新增寄存器。
  assign conditional_branch = instruction_i[6:0] == 7'b1100011 &&
      instruction_i[14:12] inside {3'b000, 3'b001, 3'b100, 3'b101, 3'b110, 3'b111};
  assign jal_instruction = instruction_i[6:0] == 7'b1101111;
  assign branch_displacement = jal_instruction ?
      {{11{instruction_i[31]}}, instruction_i[31], instruction_i[19:12],
       instruction_i[20], instruction_i[30:21], 1'b0} :
      {{19{instruction_i[31]}}, instruction_i[31], instruction_i[7],
       instruction_i[30:25], instruction_i[11:8], 1'b0};
  assign target_o = pc_i + branch_displacement;

  riscv32_branch_choice u_branch_choice (
      .backward_i       (instruction_i[31]),
      .metadata_valid_i (conditional_branch),
      .dynamic_counter_i(direction_counter_i),
      .taken_o          (conditional_taken)
  );
  assign known_o = conditional_branch || jal_instruction;
  assign taken_o = jal_instruction || (conditional_branch && conditional_taken);
endmodule
