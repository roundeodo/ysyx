module top(
    input clk,
    input rstn,
    output [7:0] digit_tube_0,
    output [7:0] digit_tube_1
);
    wire jump_flag;
    wire [3:0] jump_address;
    wire [3:0] PC_address /* verilator public */;
    sCPU_PC pc_inst(
        .en(1'b1),
        .rstn(rstn),
        .clk(clk),
        .jump(jump_flag),
        .PC_jump(jump_address),
        .PC_out(PC_address)
    );

    wire [7:0] selected_instruction;
    sCPU_instruction_ROM instruction_rom_inst(
        .PC(PC_address),
        .instruction(selected_instruction)
    );


    wire [3:0] function_selection_bus;
    wire [1:0] RD_address;
    wire [1:0] RS1_address;
    wire [1:0] RS2_address;
    wire [3:0] Immediate_number;

    sCPU_decoder decoder_inst(
        .instruction(selected_instruction),
        .FU_BUS(function_selection_bus),
        .RD(RD_address),
        .RS1(RS1_address),
        .RS2(RS2_address),
        .IMM(Immediate_number),
        .JUMP_ADDR(jump_address)
    );

    wire RF_WRITE_EN;
    assign RF_WRITE_EN = function_selection_bus[0] | function_selection_bus[2];


    wire [7:0] RF_READ_RS1; /* verilator public */
    wire [7:0] RF_READ_RS2; /* verilator public */
    wire [7:0] RF_WRITE_DATA; /* verilator public */
    sCPU_RF RF_inst(
        .RS1(RS1_address),
        .RS2(RS2_address),
        .RD(RD_address),
        .DATA(RF_WRITE_DATA),
        .EN(RF_WRITE_EN),
        .rstn(rstn),
        .clk(clk),
        .RS1_OUT(RF_READ_RS1),
        .RS2_OUT(RF_READ_RS2)
    );

    wire [3:0] calculated_address;
    wire not_compared_result;
    assign result_compare_flag = (&(RS1_OUT ~^ RS2_OUT));
    assign calculated_address = RS2_OUT + RS1_OUT;
    assign RF_WRITE_DATA = function_selection_bus[2]? Immediate_number : calculated_address;
    assign jump_flag = function_selection_bus[3] & result_compare_flag;


    bcd7seg digit_tube_0_inst(
        .seg_in(RS2_OUT[7:4]),
        .seg_out(digit_tube_0)
    );

    bcd7seg digit_tube_1_inst(
        .seg_in(RS2_OUT[3:0]),
        .seg_out(digit_tube_1)
    );

endmodule
