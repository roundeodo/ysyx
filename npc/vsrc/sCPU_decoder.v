module sCPU_decoder(
    input [7:0] instruction,
    output [3:0] FU_BUS,
    output [1:0] RD,
    output [1:0] RS1,
    output [1:0] RS2,
    output [3:0] IMM,
    output [3:0] JUMP_ADDR
);
    assign RD = instruction[5:4];
    assign RS1 = instruction[3:2];
    assign RS2 = instruction[1:0];  
    assign IMM = instruction[3:0];
    assign JUMP_ADDR = instruction[5:2];

    assign FU_BUS = 4'b0001 << instruction[7:6];


endmodule
