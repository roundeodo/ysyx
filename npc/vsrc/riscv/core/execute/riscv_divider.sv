// 共享商/余数的 radix-2 恢复余数除法；准备、迭代和结果保持分别负责明确状态。
module riscv_divider
  import riscv_pkg::*;
(
    input  logic              clk_i,
    input  logic              rst_ni,
    input  logic              flush_i,
    input  scoreboard_index_t request_index_i,
    output scoreboard_index_t result_index_o,
    input  muldiv_ctrl_t      request_operation_i,
    input  xlen_data_t        request_operand_a_i,
    input  xlen_data_t        request_operand_b_i,
    input  logic              request_valid_i,
    output logic              request_ready_o,
    output xlen_data_t        result_o,
    // 存储状态供 RAW 判断；握手 valid 另外受 flush 约束。
    output logic              result_present_o,
    output logic              result_valid_o,
    input  logic              result_ready_i
);
  localparam int unsigned ITERATION_COUNT_WIDTH = $clog2(XLEN + 1);
  typedef enum logic [2:0] {
    IDLE,
    ABSOLUTE_VALUE,
    PREPARE,
    ITERATE,
    CORRECT_SIGN,
    RESULT
  } state_e;
  state_e state_q, state_d;
  xlen_data_t quotient_q, quotient_d;
  xlen_data_t remainder_q, remainder_d;
  xlen_data_t divisor_q, divisor_d;
  logic [ITERATION_COUNT_WIDTH-1:0] remaining_bits_q, remaining_bits_d;
  logic quotient_negative_q, quotient_negative_d;
  logic remainder_negative_q, remainder_negative_d;
  logic select_remainder_q, select_remainder_d;
  logic word_result_q, word_result_d;

  // 请求只在握手时采样；W 操作先扩展低 32 位，再求绝对值，忽略输入高位。
  logic signed_operation;
  logic operand_a_negative;
  logic operand_b_negative;
  xlen_data_t operand_a;
  xlen_data_t operand_b;
  logic request_handshake;
  scoreboard_index_t request_index_q;
  assign result_index_o = request_index_q;
  assign signed_operation = request_operation_i.op inside {MULDIV_DIV, MULDIV_REM};
  assign operand_a = request_operation_i.word_operation ?
      {{(XLEN-32){signed_operation && request_operand_a_i[31]}}, request_operand_a_i[31:0]} :
      request_operand_a_i;
  assign operand_b = request_operation_i.word_operation ?
      {{(XLEN-32){signed_operation && request_operand_b_i[31]}}, request_operand_b_i[31:0]} :
      request_operand_b_i;
  assign operand_a_negative = signed_operation && operand_a[XLEN-1];
  assign operand_b_negative = signed_operation && operand_b[XLEN-1];
  assign request_handshake = request_valid_i && request_ready_o;

  // 每拍试减一次。额外借位明确区分无符号大小，不把 64 位最高位当作符号。
  logic [XLEN:0] shifted_remainder;
  logic [XLEN+1:0] trial_difference;
  logic quotient_bit;
  // 在准备阶段一次定位最高有效位。W 与 XLEN 运算都只处理绝对值的有效位。
  logic [ITERATION_COUNT_WIDTH-1:0] significant_bit_count;
  always_comb begin
    significant_bit_count = ITERATION_COUNT_WIDTH'(1);
    for (int bit_index = 0; bit_index < XLEN; bit_index++) begin
      if (quotient_q[bit_index]) significant_bit_count = ITERATION_COUNT_WIDTH'(bit_index + 1);
    end
  end
  assign shifted_remainder = {remainder_q, quotient_q[XLEN-1]};
  assign trial_difference  = {1'b0, shifted_remainder} - {2'b00, divisor_q};
  assign quotient_bit      = !trial_difference[XLEN+1];

  // 1. 输出：结果保持状态允许交付旧响应的同拍接收新请求。
  xlen_data_t selected_result;
  xlen_data_t sign_correction_operand;
  xlen_data_t sign_corrected_result;
  assign selected_result = select_remainder_q ? remainder_q : quotient_q;
  // 取负在结果有效之前完成，避免把 64 位进位链接到下一条指令的执行路径。
  assign sign_correction_operand = state_q == PREPARE ? quotient_q : selected_result;
  assign sign_corrected_result = -sign_correction_operand;
  assign result_o = word_result_q ?
      {{(XLEN-32){selected_result[31]}}, selected_result[31:0]} : selected_result;
  assign result_present_o = state_q == RESULT;
  assign result_valid_o = result_present_o && !flush_i;
  assign request_ready_o = !flush_i && (state_q == IDLE || (state_q == RESULT && result_ready_i));

  // 2. 下一状态：准备阶段处理特殊值，迭代阶段只更新算法所需的三个数据寄存器。
  always_comb begin
    state_d              = state_q;
    quotient_d           = quotient_q;
    remainder_d          = remainder_q;
    divisor_d            = divisor_q;
    remaining_bits_d     = remaining_bits_q;
    quotient_negative_d  = quotient_negative_q;
    remainder_negative_d = remainder_negative_q;
    select_remainder_d   = select_remainder_q;
    word_result_d        = word_result_q;
    unique case (state_q)
      IDLE:    ;
      ABSOLUTE_VALUE: begin
        if (remainder_negative_q) quotient_d = -quotient_q;
        if (quotient_negative_q ^ remainder_negative_q) divisor_d = -divisor_q;
        state_d = PREPARE;
      end
      PREPARE: begin
        if (divisor_q == '0) begin
          // 除零的商为全一，不再按被除数符号取反；余数恢复原被除数。
          remainder_d         = remainder_negative_q ? sign_corrected_result : quotient_q;
          quotient_d          = '1;
          quotient_negative_d = 1'b0;
          state_d             = RESULT;
        end else if (quotient_q == '0 || quotient_q < divisor_q) begin
          remainder_d = remainder_negative_q ? sign_corrected_result : quotient_q;
          quotient_d  = '0;
          state_d     = RESULT;
        end else if (divisor_q == xlen_data_t'(1)) begin
          remainder_d = '0;
          quotient_d  = quotient_negative_q ? sign_corrected_result : quotient_q;
          state_d     = RESULT;
        end else begin
          quotient_d       = quotient_q << (XLEN - int'(significant_bit_count));
          remaining_bits_d = significant_bit_count;
          state_d          = ITERATE;
        end
      end
      ITERATE: begin
        quotient_d       = {quotient_q[XLEN-2:0], quotient_bit};
        remainder_d      = quotient_bit ? trial_difference[XLEN-1:0] : shifted_remainder[XLEN-1:0];
        remaining_bits_d = remaining_bits_q - ITERATION_COUNT_WIDTH'(1);
        if (remaining_bits_q == ITERATION_COUNT_WIDTH'(1)) begin
          state_d = (select_remainder_q ? remainder_negative_q : quotient_negative_q) ?
              CORRECT_SIGN : RESULT;
        end
      end
      CORRECT_SIGN: begin
        if (select_remainder_q) remainder_d = sign_corrected_result;
        else quotient_d = sign_corrected_result;
        state_d = RESULT;
      end
      RESULT: begin
        if (result_ready_i) state_d = IDLE;
      end
      default: state_d = IDLE;
    endcase
    if (request_handshake) begin
      quotient_d           = operand_a;
      divisor_d            = operand_b;
      remainder_d          = '0;
      remaining_bits_d     = request_operation_i.word_operation ? ITERATION_COUNT_WIDTH'(32) : ITERATION_COUNT_WIDTH'(XLEN);
      quotient_negative_d  = operand_a_negative ^ operand_b_negative;
      remainder_negative_d = operand_a_negative;
      select_remainder_d   = request_operation_i.op inside {MULDIV_REM, MULDIV_REMU};
      word_result_d        = request_operation_i.word_operation;
      state_d              = (operand_a_negative || operand_b_negative) ? ABSOLUTE_VALUE : PREPARE;
    end
    if (flush_i) state_d = IDLE;
  end

  // 3. 更新：只有状态需要复位；每次请求握手覆盖全部算法载荷。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) state_q <= IDLE;
    else state_q <= state_d;
  end
  always_ff @(posedge clk_i) begin
    quotient_q           <= quotient_d;
    remainder_q          <= remainder_d;
    divisor_q            <= divisor_d;
    remaining_bits_q     <= remaining_bits_d;
    quotient_negative_q  <= quotient_negative_d;
    remainder_negative_q <= remainder_negative_d;
    select_remainder_q   <= select_remainder_d;
    word_result_q        <= word_result_d;
  end

  // 指令标识与请求同时保存，只在下一条请求获准接收时覆盖。
  always_ff @(posedge clk_i) begin
    if (request_handshake) request_index_q <= request_index_i;
  end

`ifndef SYNTHESIS
  // verilog_format: off
  property result_stable_while_stalled;
    @(posedge clk_i) disable iff (!rst_ni)
      result_valid_o && !result_ready_i && !flush_i |=>
        flush_i || (result_valid_o && $stable({result_o, result_index_o}));
  endproperty
  // verilog_format: on
  assert property (result_stable_while_stalled)
  else $error("Divider changed a stalled result");
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    request_handshake |-> request_operation_i.op inside
      {MULDIV_DIV, MULDIV_DIVU, MULDIV_REM, MULDIV_REMU})
  else $error("Non-division operation sent to divider");
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    state_q == ITERATE |-> remaining_bits_q != '0)
  else $error("Divider iterated with no bits remaining");
`endif
endmodule
