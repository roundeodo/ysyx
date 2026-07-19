// This module is only for yosys-sta experiments.
// Keep the real CPU EXU in riscv32_exu.sv unchanged: it uses package types and
// result bundles, which are better for future pipeline / OoO extension but are
// not fully accepted by the simple yosys SystemVerilog frontend used here.
//
// ALU op encoding matches riscv32_pkg::alu_op_e:
//   4'b0000 ALU_ADD
//   4'b0001 ALU_SUB
//   4'b0010 ALU_SLL
//   4'b0011 ALU_SLT
//   4'b0100 ALU_SLTU
//   4'b0101 ALU_XOR
//   4'b0110 ALU_SRL
//   4'b0111 ALU_SRA
//   4'b1000 ALU_OR
//   4'b1001 ALU_AND
module riscv32_ALU_for_sta (
    input  logic [31:0] in1,
    input  logic [31:0] in2,
    input  logic [ 3:0] op,
    output logic [31:0] out
);

  always_comb begin
    unique case (op)
      4'b0000: out = in1 + in2;
      4'b0001: out = in1 - in2;
      4'b0010: out = in1 << in2[4:0];
      4'b0011: out = {31'b0, $signed(in1) < $signed(in2)};
      4'b0100: out = {31'b0, in1 < in2};
      4'b0101: out = in1 ^ in2;
      4'b0110: out = in1 >> in2[4:0];
      4'b0111: out = $signed(in1) >>> in2[4:0];
      4'b1000: out = in1 | in2;
      4'b1001: out = in1 & in2;
      default: out = 32'b0;
    endcase
  end

endmodule
