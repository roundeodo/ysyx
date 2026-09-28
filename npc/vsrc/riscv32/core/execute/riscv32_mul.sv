// 三拍乘法器：部分积寄存 → 压缩结果寄存 → 最终64位积。
// EXU 提供各级写使能，并保存与数据对应的指令身份和有效位。
module riscv32_mul
  import riscv32_pkg::*;
(
    input  logic        clk_i,
    input  logic        partial_products_write_i,
    input  logic        compressed_sum_write_i,
    input  muldiv_op_e  operation_i,
    input  logic [31:0] operand_a_i,
    input  logic [31:0] operand_b_i,
    output logic [63:0] product_o
);
  // 第一级：低半无符号，高半按 MULH/MULHSU 扩展；四个分块乘法并行。
  logic signed [16:0] a_high, b_high, a_low, b_low;
  logic        [31:0] low_product_q, high_product_q;
  logic signed [33:0] cross_a_q, cross_b_q;

  assign a_low  = $signed({1'b0, operand_a_i[15:0]});
  assign b_low  = $signed({1'b0, operand_b_i[15:0]});
  assign a_high = $signed({((operation_i == MD_MULH) ||
                           (operation_i == MD_MULHSU)) && operand_a_i[31],
                          operand_a_i[31:16]});
  assign b_high = $signed({(operation_i == MD_MULH) && operand_b_i[31],
                          operand_b_i[31:16]});

  // 有新乘法进入第一级时写入；反压或普通指令通过时保持部分积。
  always_ff @(posedge clk_i) begin
    if (partial_products_write_i) begin
      low_product_q  <= operand_a_i[15:0] * operand_b_i[15:0];
      high_product_q <= 32'(a_high * b_high);
      cross_a_q      <= a_high * b_low;
      cross_b_q      <= a_low * b_high;
    end
  end

  // 第二级：按位权对齐四行，两层 carry-save 压缩为两行。
  logic [63:0] partial_low, partial_cross_a, partial_cross_b, partial_high;
  logic [63:0] first_sum, first_carry, second_sum, second_carry;
  logic [63:0] sum_q, carry_q;

  assign partial_low     = {32'b0, low_product_q};
  assign partial_cross_a = {{14{cross_a_q[33]}}, cross_a_q, 16'b0};
  assign partial_cross_b = {{14{cross_b_q[33]}}, cross_b_q, 16'b0};
  assign partial_high    = {high_product_q, 32'b0};
  assign first_sum       = partial_low ^ partial_cross_a ^ partial_cross_b;
  assign first_carry     = ((partial_low & partial_cross_a) |
                           (partial_low & partial_cross_b) |
                           (partial_cross_a & partial_cross_b)) << 1;
  assign second_sum      = first_sum ^ first_carry ^ partial_high;
  assign second_carry    = ((first_sum & first_carry) | (first_sum & partial_high) |
                           (first_carry & partial_high)) << 1;

  // 对应乘法推进到第二级时写入；未推进时保持，与 EXU 指令槽同步。
  always_ff @(posedge clk_i) begin
    if (compressed_sum_write_i) begin
      sum_q   <= second_sum;
      carry_q <= second_carry;
    end
  end

  // 第三级为组合相加，直接由原 EX 结果寄存器接收，不增加输出寄存器。
  assign product_o = sum_q + carry_q;
endmodule
