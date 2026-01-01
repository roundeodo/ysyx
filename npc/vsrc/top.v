module top (
    input clk,
    input rstn,
    output[15:0] LED);
reg [15:0] LED_REG;
reg [31:0] counter;
always@(posedge clk or negedge rstn)begin
    if(!rstn)begin
        LED_REG <= 16'b1;
        counter <= 32'b0;
    end
    else if(counter == 5000000) begin
        counter <= 32'b0;
        LED_REG <= {LED_REG[14:0],LED_REG[15]};
    end
    else begin
        counter <= counter + 1;
    end
end
assign LED = LED_REG;
endmodule
