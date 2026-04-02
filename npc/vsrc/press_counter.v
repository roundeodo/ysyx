module press_counter(
    input clk,
    input rstn,
    input en,
    output [7:0]count
);
    reg [7:0] press_count;
    always @(posedge clk) begin
        if(!rstn)begin
          press_count <= 8'b0;
        end
        else begin
          if(en)
          press_count <= press_count + 1;
        end
    end
    assign count = press_count;
endmodule
