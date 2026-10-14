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
  logic [31:0] branch_displacement, jump_displacement;
  logic [31:0] branch_target, jump_target;
  logic        conditional_taken;

  // 真实指令类型/立即数译码 → 目标加法与方向选择 → 输出。
  // 条件真假仍由EX确认，这里不读取GPR，也不新增寄存器。
  assign conditional_branch = instruction_i[6:0] == 7'b1100011 &&
      instruction_i[14:12] inside {3'b000, 3'b001, 3'b100, 3'b101, 3'b110, 3'b111};
  assign jal_instruction = instruction_i[6:0] == 7'b1101111;
  // B/J 位移与目标并行计算，opcode 只选择已经算好的目标。
  // 避免 I-cache 返回的 opcode 先控制位移 mux，再经过目标加法。
  assign branch_displacement =
      {{19{instruction_i[31]}}, instruction_i[31], instruction_i[7],
       instruction_i[30:25], instruction_i[11:8], 1'b0};
  assign jump_displacement =
      {{11{instruction_i[31]}}, instruction_i[31], instruction_i[19:12],
       instruction_i[20], instruction_i[30:21], 1'b0};
  logic [1:0][31:0] direct_target_array;
  for (genvar kind = 0; kind < 2; kind++) begin : g_target_add
    localparam int unsigned DISPLACEMENT_BITS = kind == 0 ? 13 : 21;
    localparam int unsigned UPPER_BITS = 32 - DISPLACEMENT_BITS;
    logic [DISPLACEMENT_BITS-1:0] displacement;
    logic [DISPLACEMENT_BITS:0] low_sum;
    logic [UPPER_BITS-1:0] upper_pc, upper_increment, upper_decrement, upper_result;

    // 位移只含13/21位。高位PC的三种候选与指令返回路径并行计算，
    // 低位进位和符号在末端选择高位，不让迟到的立即数经过全宽进位链。
    assign displacement = kind == 0 ? branch_displacement[DISPLACEMENT_BITS-1:0] :
                                     jump_displacement[DISPLACEMENT_BITS-1:0];
    assign low_sum         = {1'b0, pc_i[DISPLACEMENT_BITS-1:0]} + {1'b0, displacement};
    assign upper_pc        = pc_i[31:DISPLACEMENT_BITS];
    assign upper_increment = upper_pc + 1'b1;
    assign upper_decrement = upper_pc - 1'b1;
    assign upper_result = (low_sum[DISPLACEMENT_BITS] == displacement[DISPLACEMENT_BITS-1]) ?
        upper_pc : (displacement[DISPLACEMENT_BITS-1] ? upper_decrement : upper_increment);
    assign direct_target_array[kind] = {upper_result, low_sum[DISPLACEMENT_BITS-1:0]};
  end
  assign branch_target = direct_target_array[0];
  assign jump_target   = direct_target_array[1];
  assign target_o = jal_instruction ? jump_target : branch_target;

  riscv32_branch_choice u_branch_choice (
      .backward_i       (instruction_i[31]),
      .metadata_valid_i (1'b1),
      .dynamic_counter_i(direction_counter_i),
      .taken_o          (conditional_taken)
  );
  assign known_o = conditional_branch || jal_instruction;
  assign taken_o = jal_instruction || (conditional_branch && conditional_taken);
endmodule
