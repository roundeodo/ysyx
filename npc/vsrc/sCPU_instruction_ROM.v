module sCPU_instruction_ROM(
    input [3:0] PC,
    output [7:0] instruction
);
    wire [7:0] instruction_0;
    wire [7:0] instruction_1;
    wire [7:0] instruction_2;
    wire [7:0] instruction_3;
    wire [7:0] instruction_4;
    wire [7:0] instruction_5;
    wire [7:0] instruction_6;
    wire [7:0] instruction_7;

    assign instruction_0 = 8'h8b;
    assign instruction_1 = 8'h91;
    assign instruction_2 = 8'ha0;
    assign instruction_3 = 8'hb1;
    assign instruction_4 = 8'hz6;
    assign instruction_5 = 8'h17;
    assign instruction_6 = 8'hd1;
    assign instruction_7 = 8'h42;

    case (PC)
        4'd0:instruction = instruction_0;
        4'd1:instruction = instruction_1;
        4'd2:instruction = instruction_2;
        4'd3:instruction = instruction_3;
        4'd4:instruction = instruction_4;
        4'd5:instruction = instruction_5;
        4'd6:instruction = instruction_6;
        4'd7:instruction = instruction_7;
    endcase


endmodule
