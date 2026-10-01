// 当前指令已由I-cache返回：精确计算B/J目标；JALR仍交给现有预测/EX路径。
module riscv32_direct_target (
    input  logic [31:0] pc_i,
    input  logic [31:0] instruction_i,
    input  logic [ 1:0] direction_counter_i,
    output logic        known_o,
    output logic        taken_o,
    output logic [31:0] target_o
);
  logic conditional, direct_jump;
  logic [31:0] displacement;
  logic conditional_taken;

  assign conditional = instruction_i[6:0] == 7'b1100011 &&
                       instruction_i[14:12] inside {3'b000,3'b001,3'b100,3'b101,3'b110,3'b111};
  assign direct_jump = instruction_i[6:0] == 7'b1101111;
  assign displacement = direct_jump ?
      {{11{instruction_i[31]}},instruction_i[31],instruction_i[19:12],instruction_i[20],instruction_i[30:21],1'b0} :
      {{19{instruction_i[31]}},instruction_i[31],instruction_i[7],instruction_i[30:25],instruction_i[11:8],1'b0};
  assign target_o = pc_i + displacement;

  riscv32_branch_choice u_branch_choice (
      .backward_i(instruction_i[31]),
      .metadata_valid_i(conditional),
      .dynamic_counter_i(direction_counter_i),
      .taken_o(conditional_taken)
  );
  assign known_o = conditional || direct_jump;
  assign taken_o = direct_jump || (conditional && conditional_taken);
endmodule
