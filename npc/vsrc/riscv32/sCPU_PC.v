module sCPU_PC(
    input en,
    input rstn,
    input clk,
    input jump,
    input [3:0] PC_jump,
    output [3:0] PC_out
);

    reg [3:0] PC_Q;
    wire [3:0] PC_4;
    assign PC_4 = PC_Q + 1;

    always @(posedge clk or negedge rstn) begin
        if(!rstn)begin
          PC_Q <= 4'b0;
        end
        else if(en) begin
            if (jump) begin
                PC_Q <= PC_jump;
            end
            else if(PC_4!=4'b1000) begin
                PC_Q <= PC_4;
            end
            else begin
                PC_Q <= 4'b0111;
            end
        end
    end

    assign PC_out = PC_Q;
endmodule
