module top (
    input clk,
    input rstn,
    output [6:0] digit_tube_0,
    output [6:0] digit_tube_1
  );

wire [7:0] LSFR_VALUE;

  LSFR LSFR_inst(
    .clk(clk),
    .rstn(rstn),
    .LSFR_out(LSFR_VALUE)
  );

  bcd7seg u_digit_tube_1(
    .seg_in(LSFR_VALUE[7:4]),
    .seg_out(digit_tube_1)
  );

  bcd7seg u_digit_tube(
    .seg_in(LSFR_VALUE[3:0]),
    .seg_out(digit_tube_0)
  );

endmodule

