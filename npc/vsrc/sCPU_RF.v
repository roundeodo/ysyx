module sCPU_RF(
    input [1:0] RS1,
    input [1:0] RS2,
    input [1:0] RD,
    input [7:0] DATA,
    input EN,
    input rstn,
    input clk,
    output [7:0] RS1_OUT,
    output [7:0] RS2_OUT
);
    reg [7:0] register_file [0:3];

    assign RS1_OUT = register_file[RS1];
    assign RS2_OUT = register_file[RS2];

    integer  i;
    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            for(i = 0; i < 4; i=i+1)begin
              register_file[i] <= 8'b0;
            end
        end
        else if (EN) begin
            register_file[RD] <= DATA;
        end
    end

endmodule
