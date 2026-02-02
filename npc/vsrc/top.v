module top (
  input enable, 
  input [7:0] in, 
  output [3:0] encoder_out,
  output [6:0] digit_tube_out
  );


wire [3:0] encoder83_out;

encoder83 encoder(
  .x(in),
  .en(enable),
  .y(encoder83_out[2:0]),
  .valid(encoder83_out[3])
);

assign encoder_out = encoder83_out;

bcd7seg bcd1(
  .seg_in({1'b0,encoder83_out[2:0]}),
  .seg_out(digit_tube_out)
);

endmodule

