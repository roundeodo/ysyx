// 整数组合运算：加减/比较共用加法器，左右移位与 W 操作共用移位器。
module riscv_alu
  import riscv_pkg::*;
(
    input  alu_op_e    operation_i,
    input  xlen_data_t operand_a_i,
    input  xlen_data_t operand_b_i,
    output xlen_data_t result_o
);
  localparam int unsigned WORD_WIDTH = 32;
  localparam int unsigned SHIFT_WIDTH = $clog2(XLEN);

  logic word_operation;
  assign word_operation = operation_i inside {ALU_ADDW, ALU_SUBW, ALU_SLLW, ALU_SRLW, ALU_SRAW};

  // SUB 与比较使用 A + ~B + 1；W 算术取同一加法器的低 32 位。
  logic subtract_operation;
  logic [XLEN:0] arithmetic_result;
  logic unsigned_less;
  logic signed_less;
  assign subtract_operation = operation_i inside {ALU_SUB, ALU_SUBW, ALU_SLT, ALU_SLTU};
  assign arithmetic_result = {1'b0, operand_a_i} +
      {1'b0, operand_b_i ^ {XLEN{subtract_operation}}} + {{XLEN{1'b0}}, subtract_operation};
  assign unsigned_less = !arithmetic_result[XLEN];
  assign signed_less = (operand_a_i[XLEN-1] != operand_b_i[XLEN-1]) ?
      operand_a_i[XLEN-1] : unsigned_less;

  // 左移通过输入/输出位序反转复用右移网络；算术右移独立选择符号填充。
  logic shift_left;
  logic shift_arithmetic;
  logic [SHIFT_WIDTH-1:0] shift_amount;
  xlen_data_t shift_operand;
  xlen_data_t shift_input;
  logic signed [XLEN:0] shifted_value;
  xlen_data_t shift_result;
  assign shift_left = operation_i inside {ALU_SLL, ALU_SLLW};
  assign shift_arithmetic = operation_i inside {ALU_SRA, ALU_SRAW};
  assign shift_amount = word_operation ?
      {{(SHIFT_WIDTH-5){1'b0}}, operand_b_i[4:0]} : operand_b_i[SHIFT_WIDTH-1:0];
  assign shift_operand = word_operation ?
      {{(XLEN-WORD_WIDTH){shift_arithmetic && operand_a_i[WORD_WIDTH-1]}},
        operand_a_i[WORD_WIDTH-1:0]} : operand_a_i;
  for (genvar bit_index = 0; bit_index < XLEN; bit_index++) begin : gen_shift_bit_order
    assign shift_input[bit_index] = shift_left ?
        shift_operand[XLEN-1-bit_index] : shift_operand[bit_index];
    assign shift_result[bit_index] = shift_left ?
        shifted_value[XLEN-1-bit_index] : shifted_value[bit_index];
  end
  assign shifted_value = $signed(
      {shift_arithmetic && shift_input[XLEN-1], shift_input}
  ) >>> shift_amount;

  xlen_data_t selected_result;
  always_comb begin
    selected_result = '0;
    unique case (operation_i)
      ALU_ADD, ALU_SUB, ALU_ADDW, ALU_SUBW:
        selected_result = arithmetic_result[XLEN-1:0];
      ALU_SLT:
        selected_result[0] = signed_less;
      ALU_SLTU:
        selected_result[0] = unsigned_less;
      ALU_XOR:
        selected_result = operand_a_i ^ operand_b_i;
      ALU_OR:
        selected_result = operand_a_i | operand_b_i;
      ALU_AND:
        selected_result = operand_a_i & operand_b_i;
      ALU_SLL, ALU_SRL, ALU_SRA, ALU_SLLW, ALU_SRLW, ALU_SRAW:
        selected_result = shift_result;
      default: ;
    endcase
  end
  assign result_o = word_operation ?
      {{(XLEN-WORD_WIDTH){selected_result[WORD_WIDTH-1]}}, selected_result[WORD_WIDTH-1:0]} :
      selected_result;
endmodule
