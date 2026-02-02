module top (
    input [3:0] a,
    input [3:0] b,
    input [2:0] opcode,
    output [6:0] digit_tube,
    output zero,
    output overflow,
    output negative,
    output carry
  );

  wire [3:0] alu_out_w;

  alu #(.WIDTH(4)) u_alu(
    .opcode(opcode),
    .alu_in_a(a),
    .alu_in_b(b),
    .alu_out(alu_out_w),
    .alu_zero(zero),
    .alu_overflow(overflow),
    .alu_negtive(negative),
    .alu_carry(carry) 
  );

  bcd7seg u_digit_tube(
    .seg_in(alu_out_w),
    .seg_out(digit_tube)
  );



endmodule

