// RV32 M 扩展：17x17 乘累加和逐位除法，共享算法寄存器。
// ID/EX 从启动到结果握手始终保持 operation/operands；flush 取消当前运算。
module riscv32_muldiv
  import riscv32_pkg::*;
(
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic        flush_i,
    input  logic        operation_valid_i,
    input  muldiv_op_e   operation_i,
    input  logic [31:0]  operand_a_i,
    input  logic [31:0]  operand_b_i,
    output logic [31:0]  result_o,
    output logic        result_available_o,
    input  logic        result_ready_i
);
  typedef enum logic [2:0] {
    IDLE, MUL_CROSS_A, MUL_CROSS_B, MUL_HIGH, DIV_STEP, DIV_SIGN
  } state_e;

  state_e      state_q, state_d;
  logic [33:0] accumulator_q;
  logic [31:0] quotient_q;
  logic [31:0] divisor_q;
  logic [4:0]  divide_step_q;

  // 操作属性和符号准备。操作数已由 ID/EX 保存，不在本单元重复寄存。
  logic        multiply_operation;
  logic        signed_divide;
  logic        remainder_operation;
  logic        product_a_signed, product_b_signed;
  logic [31:0] dividend_magnitude, divisor_magnitude;
  logic        negate_result;
  logic        shortcut_present;
  logic [31:0] shortcut_result;

  assign multiply_operation = (operation_i == MD_MUL) || (operation_i == MD_MULH) ||
      (operation_i == MD_MULHSU) || (operation_i == MD_MULHU);
  assign signed_divide = (operation_i == MD_DIV) || (operation_i == MD_REM);
  assign remainder_operation = (operation_i == MD_REM) || (operation_i == MD_REMU);
  assign product_a_signed = (operation_i == MD_MULH) || (operation_i == MD_MULHSU);
  assign product_b_signed = (operation_i == MD_MULH);
  assign dividend_magnitude = (signed_divide && operand_a_i[31]) ?
      -operand_a_i : operand_a_i;
  assign divisor_magnitude = (signed_divide && operand_b_i[31]) ?
      -operand_b_i : operand_b_i;
  assign negate_result = signed_divide && (remainder_operation ?
      operand_a_i[31] : (operand_a_i[31] ^ operand_b_i[31]));

  // 可直接确定的运算在入口完成，不进入迭代或增加结果搬运周期。
  always_comb begin
    shortcut_present = 1'b0;
    shortcut_result  = '0;
    if (multiply_operation) begin
      shortcut_present = (operand_a_i == '0) || (operand_b_i == '0);
    end else if (operand_b_i == '0) begin
      shortcut_present = 1'b1;
      shortcut_result  = remainder_operation ? operand_a_i : 32'hffff_ffff;
    end else if (dividend_magnitude < divisor_magnitude) begin
      shortcut_present = 1'b1;
      shortcut_result  = remainder_operation ? operand_a_i : 32'b0;
    end else if (divisor_magnitude == 32'd1) begin
      shortcut_present = 1'b1;
      shortcut_result  = remainder_operation ? 32'b0 :
          ((signed_divide && operand_b_i[31]) ? -operand_a_i : operand_a_i);
    end
  end

  // 低半无符号、高半按操作符号扩展；四个部分积复用同一个乘法器。
  logic signed [16:0] product_a, product_b;
  logic signed [33:0] product_accumulator, product_sum;

  always_comb begin
    product_a = $signed({1'b0, operand_a_i[15:0]});
    product_b = $signed({1'b0, operand_b_i[15:0]});
    if ((state_q == MUL_CROSS_A) || (state_q == MUL_HIGH))
      product_a = $signed({product_a_signed && operand_a_i[31], operand_a_i[31:16]});
    if ((state_q == MUL_CROSS_B) || (state_q == MUL_HIGH))
      product_b = $signed({product_b_signed && operand_b_i[31], operand_b_i[31:16]});
  end
  // 累加项直接进入乘法压缩树；首拍为零，之后使用上拍部分和。
  assign product_accumulator = (state_q == IDLE) ? 34'sb0 : $signed(accumulator_q);
  assign product_sum = product_a * product_b + product_accumulator;

  // 除法试减独立于乘法器，避免“部分积 → 选择 → 减法 → 借位选择”的长组合链。
  logic [32:0] shifted_remainder;
  logic [33:0] trial_remainder;
  logic [31:0] next_remainder, next_quotient;
  logic [31:0] unsigned_result, signed_result;

  assign shifted_remainder = {accumulator_q[31:0], quotient_q[31]};
  assign trial_remainder = {1'b0, shifted_remainder} - {2'b0, divisor_q};
  assign next_remainder = trial_remainder[33] ? shifted_remainder[31:0] : trial_remainder[31:0];
  assign next_quotient = {quotient_q[30:0], !trial_remainder[33]};
  assign unsigned_result = remainder_operation ? accumulator_q[31:0] : quotient_q;
  assign signed_result = negate_result ? -unsigned_result : unsigned_result;

  // 结果可用只由算法状态和操作决定，不串联发出/恢复条件。
  // EXU 负责用 valid 和 issue_allowed 门控交付；反压时保持末拍状态及结果。
  always_comb begin
    result_o           = '0;
    result_available_o = 1'b0;
    unique case (state_q)
      IDLE: begin
        result_o           = shortcut_result;
        result_available_o = shortcut_present;
      end
      MUL_CROSS_B: begin
        result_o           = {product_sum[15:0], quotient_q[15:0]};
        result_available_o = (operation_i == MD_MUL);
      end
      MUL_HIGH: begin
        result_o           = product_sum[31:0];
        result_available_o = 1'b1;
      end
      DIV_SIGN: begin
        result_o           = signed_result;
        result_available_o = 1'b1;
      end
      default: ;
    endcase
  end

  // 下一状态：入口启动，内部运算逐拍推进，末拍仅在结果握手时离开。
  always_comb begin
    state_d = state_q;
    if (operation_valid_i) begin
      unique case (state_q)
        IDLE: if (!shortcut_present) state_d = multiply_operation ? MUL_CROSS_A : DIV_STEP;
        MUL_CROSS_A: state_d = MUL_CROSS_B;
        MUL_CROSS_B: begin
          if (operation_i != MD_MUL) state_d = MUL_HIGH;
          else if (result_ready_i) state_d = IDLE;
        end
        MUL_HIGH, DIV_SIGN: if (result_ready_i) state_d = IDLE;
        DIV_STEP: if (divide_step_q == 5'd31) state_d = DIV_SIGN;
        default: state_d = IDLE;
      endcase
    end
  end

  // 状态唯一管理有效性；宽数据仅在各算法需要时写入，不为 flush 清零。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) state_q <= IDLE;
    else if (flush_i) state_q <= IDLE;
    else state_q <= state_d;
  end

  always_ff @(posedge clk_i) begin
    if (operation_valid_i && !flush_i) begin
      unique case (state_q)
        IDLE: if (!shortcut_present) begin
          if (multiply_operation) begin
            accumulator_q <= {16'b0, product_sum[33:16]};
            quotient_q    <= {16'b0, product_sum[15:0]};
          end else begin
            accumulator_q <= '0;
            quotient_q    <= dividend_magnitude;
            divisor_q     <= divisor_magnitude;
            divide_step_q <= '0;
          end
        end
        MUL_CROSS_A: accumulator_q <= product_sum;
        MUL_CROSS_B: if (operation_i != MD_MUL)
          accumulator_q <= {{16{product_sum[33]}}, product_sum[33:16]};
        DIV_STEP: begin
          accumulator_q <= {2'b0, next_remainder};
          quotient_q    <= next_quotient;
          divide_step_q <= divide_step_q + 5'd1;
        end
        default: ;
      endcase
    end
  end
endmodule
