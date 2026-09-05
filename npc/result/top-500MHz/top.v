//Generate the verilog at 2026-01-13T19:10:35 by iSTA.
module top (
clk,
rst,
in,
out
);

input clk ;
input rst ;
input in ;
output out ;

wire clk ;
wire rst ;
wire in ;
wire out ;
wire out_reg_p_D ;
wire \r1.dout_0_ ;
wire \r1.dout_0__reg_p_D ;
wire \r2.dout_0_ ;
wire \r2.dout_0__reg_n_D ;


NOR2BX0P5H7L in_NOR2BX0P5H7L_AN ( .AN(in ), .B(rst ), .Z(\r1.dout_0__reg_p_D ) );
DFFQX1H7L out_reg_p ( .CK(clk ), .D(out_reg_p_D ), .Q(out ) );
NOR2BX1H7L \r1.dout_0__NOR2BX1H7L_AN ( .AN(\r1.dout_0_ ), .B(rst ), .Z(\r2.dout_0__reg_n_D ) );
DFFQX1H7L \r1.dout_0__reg_p ( .CK(clk ), .D(\r1.dout_0__reg_p_D ), .Q(\r1.dout_0_ ) );
NOR2BX0P5H7L \r2.dout_0__NOR2BX0P5H7L_AN ( .AN(\r2.dout_0_ ), .B(rst ), .Z(out_reg_p_D ) );
DFFNQX2H7L \r2.dout_0__reg_n ( .CKN(clk ), .D(\r2.dout_0__reg_n_D ), .Q(\r2.dout_0_ ) );

endmodule
