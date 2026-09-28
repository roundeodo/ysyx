// 单上下文逐位除法。ID/EX 保持操作与操作数，最终拍直接交付并前递。
module riscv32_div
  import riscv32_pkg::*;
(
    input  logic              clk_i,
    input  logic              rst_ni,
    input  logic              flush_i,
    input  logic              operation_valid_i,
    input  muldiv_op_e        operation_i,
    input  logic       [31:0] operand_a_i,
    input  logic       [31:0] operand_b_i,
    output logic       [31:0] result_o,
    output logic              result_available_o,
    input  logic              result_ready_i
);
  typedef enum logic [1:0] {
    IDLE,
    DIV_STEP,
    DIV_SIGN
  } state_e;
  state_e state_q, state_d;
  logic [31:0] remainder_q, quotient_q, divisor_q;
  logic [4:0] step_q;

  // 入口符号与快捷结果；除零、幅值不足、除数为 ±1 不进入迭代。
  logic signed_divide, remainder_operation, negate_result;
  logic [31:0] dividend_magnitude, divisor_magnitude, shortcut_result;
  logic shortcut_present;
  assign signed_divide = (operation_i == MD_DIV) || (operation_i == MD_REM);
  assign remainder_operation = (operation_i == MD_REM) || (operation_i == MD_REMU);
  assign dividend_magnitude = signed_divide && operand_a_i[31] ? -operand_a_i : operand_a_i;
  assign divisor_magnitude = signed_divide && operand_b_i[31] ? -operand_b_i : operand_b_i;
  assign negate_result = signed_divide && (remainder_operation ? operand_a_i[31] :
                                          (operand_a_i[31] ^ operand_b_i[31]));
  always_comb begin
    shortcut_present = 1'b1;
    shortcut_result  = '0;
    if (operand_b_i == '0)
      shortcut_result = remainder_operation ? operand_a_i : 32'hffff_ffff;
    else if (dividend_magnitude < divisor_magnitude)
      shortcut_result = remainder_operation ? operand_a_i : 32'b0;
    else if (divisor_magnitude == 32'd1)
      shortcut_result = remainder_operation ? 32'b0 :
          (signed_divide && operand_b_i[31] ? -operand_a_i : operand_a_i);
    else
      shortcut_present = 1'b0;
  end

  // 每拍一位商：移入被除数下一位，试减，按借位选择余数。
  logic [32:0] shifted_remainder;
  logic [33:0] trial_remainder;
  logic [31:0] next_remainder, next_quotient, unsigned_result;
  assign shifted_remainder = {remainder_q, quotient_q[31]};
  assign trial_remainder = {1'b0, shifted_remainder} - {2'b0, divisor_q};
  assign next_remainder = trial_remainder[33] ? shifted_remainder[31:0] : trial_remainder[31:0];
  assign next_quotient = {quotient_q[30:0], !trial_remainder[33]};
  assign unsigned_result = remainder_operation ? remainder_q : quotient_q;

  always_comb begin
    result_o = '0;
    result_available_o = 1'b0;
    case (state_q)
      IDLE: begin
        result_o = shortcut_result;
        result_available_o = shortcut_present;
      end
      DIV_SIGN: begin
        result_o = negate_result ? -unsigned_result : unsigned_result;
        result_available_o = 1'b1;
      end
      default: ;
    endcase
  end

  always_comb begin
    state_d = state_q;
    if (operation_valid_i) begin
      case (state_q)
        IDLE: if (!shortcut_present) state_d = DIV_STEP;
        DIV_STEP: if (step_q == 5'd31) state_d = DIV_SIGN;
        DIV_SIGN: if (result_ready_i) state_d = IDLE;
        default: state_d = IDLE;
      endcase
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)
      state_q <= IDLE;
    else if (flush_i)
      state_q <= IDLE;
    else
      state_q <= state_d;
  end
  always_ff @(posedge clk_i) begin
    if (operation_valid_i && !flush_i) begin
      case (state_q)
        IDLE:
        if (!shortcut_present) begin
          remainder_q <= '0;
          quotient_q <= dividend_magnitude;
          divisor_q <= divisor_magnitude;
          step_q <= '0;
        end
        DIV_STEP: begin
          remainder_q <= next_remainder;
          quotient_q <= next_quotient;
          step_q <= step_q + 5'd1;
        end
        default: ;
      endcase
    end
  end
endmodule
