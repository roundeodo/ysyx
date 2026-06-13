module sCPU_instruction_ROM(
    input [3:0] PC,
    output reg [7:0] instruction
);
    wire [7:0] rom_array [0:15];

    assign rom_array[0] = 8'h8b; 
    assign rom_array[1] = 8'h91;
    assign rom_array[2] = 8'ha0; 
    assign rom_array[3] = 8'hb1;
    assign rom_array[4] = 8'h26; 
    assign rom_array[5] = 8'h17;
    assign rom_array[6] = 8'hd1; 
    assign rom_array[7] = 8'h42;

    genvar i;
    generate
        for (i = 8; i < 16; i = i + 1) begin
            assign rom_array[i] = 8'h00;
        end
    endgenerate

    assign instruction = rom_array[PC];


endmodule
