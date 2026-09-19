// 独立综合实验：4 位组合左移器，2 位移位量，无流水寄存器。
module shl4_for_sta (
    input  logic [3:0] operand_i,
    input  logic [1:0] shift_amount_i,
    output logic [3:0] result_o
);

  assign result_o = operand_i << shift_amount_i;

endmodule
