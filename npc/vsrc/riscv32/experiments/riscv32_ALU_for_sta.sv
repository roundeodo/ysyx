// 独立组合 ALU 综合实验，不在 CPU 的正式 filelist 中。
// 4 位操作码沿用 RV32 ALU 的 0..9 编码；CPU 执行单元见 riscv32_exu.sv。
// 加减、移位、比较和位运算由 case 选择，移位量取操作数 B 的低 5 位。
module riscv32_ALU_for_sta (
    input  logic [31:0] operand_a_i,
    input  logic [31:0] operand_b_i,
    input  logic [ 3:0] alu_op_i,
    output logic [31:0] result_o
);

  always_comb begin
    unique case (alu_op_i)
      4'b0000: result_o = operand_a_i + operand_b_i;
      4'b0001: result_o = operand_a_i - operand_b_i;
      4'b0010: result_o = operand_a_i << operand_b_i[4:0];
      4'b0011: result_o = {31'b0, $signed(operand_a_i) < $signed(operand_b_i)};
      4'b0100: result_o = {31'b0, operand_a_i < operand_b_i};
      4'b0101: result_o = operand_a_i ^ operand_b_i;
      4'b0110: result_o = operand_a_i >> operand_b_i[4:0];
      4'b0111: result_o = $signed(operand_a_i) >>> operand_b_i[4:0];
      4'b1000: result_o = operand_a_i | operand_b_i;
      4'b1001: result_o = operand_a_i & operand_b_i;
      default: result_o = 32'b0;
    endcase
  end

endmodule
