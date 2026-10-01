// 三级乘法流水：部分积 → 进位保存压缩 → 分半求和。
// 高半部的两种进位结果并行保存，末级只选择和格式化，由 scoreboard 完成口采样。
// 输出反压暂停全部有效级，flush 清除有效性；载荷不需要复位。
module riscv_multiplier
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
  localparam int unsigned PART_WIDTH = 16;
  localparam int unsigned PART_COUNT = XLEN / PART_WIDTH;
  localparam int unsigned PRODUCT_COUNT = PART_COUNT * PART_COUNT;
  localparam int unsigned TERM_COUNT = PRODUCT_COUNT + 3;
  localparam int unsigned COMPRESSION_LEVELS = 6;
  typedef logic [2*XLEN-1:0] product_t;
  typedef struct packed {
    logic high_half;
    logic word_result;
  } result_format_t;

  initial begin
    if (XLEN != 64) $fatal(1, "Multiplier requires the current RV64 configuration");
  end

  // 全局推进仅由结果槽容量决定；控制与各级数据在同一使能下前进。
  logic [2:0] valid_vector_q;
  result_format_t format_array_q[3];
  scoreboard_index_t index_array_q[3];
  assign result_index_o = index_array_q[2];
  logic pipeline_advance;
  logic request_handshake;
  assign pipeline_advance  = !valid_vector_q[2] || result_ready_i;
  assign request_ready_o   = pipeline_advance && !flush_i;
  assign request_handshake = request_valid_i && request_ready_o;
  assign result_present_o  = valid_vector_q[2];
  assign result_valid_o    = result_present_o && !flush_i;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) valid_vector_q <= '0;
    else if (flush_i) valid_vector_q <= '0;
    else if (pipeline_advance) valid_vector_q <= {valid_vector_q[1:0], request_handshake};
  end

  // 第一级：16 位分块使用乘法运算符，给输入前递保留时序余量。
  // 所有指令共用无符号部分积与符号修正，不复制高半部数据通路。
  logic operand_a_negative;
  logic operand_b_negative;
  logic [2*PART_WIDTH-1:0] partial_product_array_q[PRODUCT_COUNT];
  xlen_data_t correction_array_q[2];
  logic [1:0] correction_carry_q;
  assign operand_a_negative = request_operand_a_i[XLEN-1] &&
      (request_operation_i.op inside {MULDIV_MULH, MULDIV_MULHSU});
  assign operand_b_negative = request_operand_b_i[XLEN-1] && request_operation_i.op == MULDIV_MULH;
  always_ff @(posedge clk_i) begin
    if (request_handshake) begin
      index_array_q[0] <= request_index_i;
      for (int a_index = 0; a_index < PART_COUNT; a_index++) begin
        for (int b_index = 0; b_index < PART_COUNT; b_index++) begin
          partial_product_array_q[a_index*PART_COUNT+b_index] <=
              request_operand_a_i[a_index*PART_WIDTH+:PART_WIDTH] *
              request_operand_b_i[b_index*PART_WIDTH+:PART_WIDTH];
        end
      end
      // -B = ~B + 1；修正只影响高半部，进位一并送入压缩树。
      correction_array_q[0]         <= operand_a_negative ? ~request_operand_b_i : '0;
      correction_array_q[1]         <= operand_b_negative ? ~request_operand_a_i : '0;
      correction_carry_q            <= {1'b0, operand_a_negative} + {1'b0, operand_b_negative};
      format_array_q[0].high_half   <= request_operation_i.op != MULDIV_MUL;
      format_array_q[0].word_result <= request_operation_i.word_operation;
    end
  end

  // 第二级：对齐部分积和符号修正，逐级做三输入压缩。本级不传播跨位进位。
  function automatic product_t sum_bits(input product_t a, b, c);
    return a ^ b ^ c;
  endfunction
  function automatic product_t carry_bits(input product_t a, b, c);
    return ((a & b) | (a & c) | (b & c)) << 1;
  endfunction
  function automatic int unsigned terms_at_level(input int unsigned level);
    int unsigned count;
    count = TERM_COUNT;
    for (int index = 0; index < level; index++) count = (count / 3) * 2 + count % 3;
    return count;
  endfunction
  product_t compression_array[COMPRESSION_LEVELS+1][TERM_COUNT];
  product_t sum_vector_q;
  product_t carry_vector_q;
  for (genvar a_index = 0; a_index < PART_COUNT; a_index++) begin : gen_a_part
    for (genvar b_index = 0; b_index < PART_COUNT; b_index++) begin : gen_b_part
      assign compression_array[0][a_index*PART_COUNT+b_index] =
          product_t'(partial_product_array_q[a_index*PART_COUNT+b_index]) <<
          ((a_index+b_index)*PART_WIDTH);
    end
  end
  assign compression_array[0][PRODUCT_COUNT] = {correction_array_q[0], {XLEN{1'b0}}};
  assign compression_array[0][PRODUCT_COUNT+1] = {correction_array_q[1], {XLEN{1'b0}}};
  assign compression_array[0][PRODUCT_COUNT+2] = {
    {(XLEN - 2) {1'b0}}, correction_carry_q, {XLEN{1'b0}}
  };
  for (genvar level = 0; level < COMPRESSION_LEVELS; level++) begin : gen_compression
    localparam int unsigned INPUT_COUNT = terms_at_level(level);
    localparam int unsigned GROUP_COUNT = INPUT_COUNT / 3;
    localparam int unsigned OUTPUT_COUNT = terms_at_level(level + 1);
    for (genvar group_index = 0; group_index < GROUP_COUNT; group_index++) begin : gen_group
      assign compression_array[level+1][2*group_index] = sum_bits(
          compression_array[level][3*group_index],
          compression_array[level][3*group_index+1],
          compression_array[level][3*group_index+2]
      );
      assign compression_array[level+1][2*group_index+1] = carry_bits(
          compression_array[level][3*group_index],
          compression_array[level][3*group_index+1],
          compression_array[level][3*group_index+2]
      );
    end
    for (genvar index = 0; index < INPUT_COUNT % 3; index++) begin : gen_remainder
      assign compression_array[level+1][2*GROUP_COUNT+index] =
          compression_array[level][3*GROUP_COUNT+index];
    end
    for (genvar index = OUTPUT_COUNT; index < TERM_COUNT; index++) begin : gen_unused
      assign compression_array[level+1][index] = '0;
    end
  end
  initial begin
    if (terms_at_level(COMPRESSION_LEVELS) != 2)
      $fatal(1, "Multiplier compression must end with two vectors");
  end
  always_ff @(posedge clk_i) begin
    if (pipeline_advance && valid_vector_q[0]) begin
      sum_vector_q      <= compression_array[COMPRESSION_LEVELS][0];
      carry_vector_q    <= compression_array[COMPRESSION_LEVELS][1];
      format_array_q[1] <= format_array_q[0];
      index_array_q[1]  <= index_array_q[0];
    end
  end

  // 第三级：低半部产生跨界进位；高半部先并行相加，避免一次串过 128 位进位链。
  logic [XLEN:0] low_sum;
  xlen_data_t low_result_q;
  xlen_data_t high_sum_q;
  xlen_data_t high_sum_with_carry_q;
  logic low_carry_q;
  assign low_sum = {1'b0, sum_vector_q[XLEN-1:0]} + {1'b0, carry_vector_q[XLEN-1:0]};
  always_ff @(posedge clk_i) begin
    if (pipeline_advance && valid_vector_q[1]) begin
      low_result_q <= low_sum[XLEN-1:0];
      low_carry_q  <= low_sum[XLEN];
      high_sum_q   <= sum_vector_q[2*XLEN-1:XLEN] + carry_vector_q[2*XLEN-1:XLEN];
      // ~(~a + ~b) = a + b + 1；与无进位和并行，避免先求和再串联自增器。
      high_sum_with_carry_q <= ~(~sum_vector_q[2*XLEN-1:XLEN] + ~carry_vector_q[2*XLEN-1:XLEN]);
      format_array_q[2]     <= format_array_q[1];
      index_array_q[2]      <= index_array_q[1];
    end
  end

  // 组合结果：从已保存的分半加法结果形成架构值，不另加输出寄存器。
  // 输出反压时第三级保持，因而结果稳定；同拍可交付到 scoreboard 并前递。
  xlen_data_t selected_result;
  assign selected_result = format_array_q[2].high_half ?
      (low_carry_q ? high_sum_with_carry_q : high_sum_q) : low_result_q;
  assign result_o = format_array_q[2].word_result ?
      {{(XLEN-32){selected_result[31]}}, selected_result[31:0]} : selected_result;

`ifndef SYNTHESIS
  // verilog_format: off
  property result_stable_while_stalled;
    @(posedge clk_i) disable iff (!rst_ni)
      result_valid_o && !result_ready_i && !flush_i |=>
        flush_i || (result_valid_o && $stable({result_o, result_index_o}));
  endproperty
  // verilog_format: on
  assert property (result_stable_while_stalled)
  else $error("Multiplier changed a stalled result");
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    request_handshake |-> request_operation_i.op inside
      {MULDIV_MUL, MULDIV_MULH, MULDIV_MULHSU, MULDIV_MULHU})
  else $error("Non-multiply operation sent to multiplier");
`endif
endmodule
