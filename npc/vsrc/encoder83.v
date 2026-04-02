module encoder83(
  input  [7:0] x,
  input  en,
  output reg [2:0]y,
  output reg valid
);
  always @(*) begin
    if(en) begin
      casez(x)
        8'b1???????:begin
          y = 3'b111;
          valid = 1'b1;
        end
        8'b01??????:begin
          y = 3'b110;
          valid = 1'b1;
        end
        8'b001?????:begin
          y = 3'b101;
          valid = 1'b1;        
        end
        8'b0001????:begin
          y = 3'b100;
          valid = 1'b1;        
        end
        8'b00001???:begin
          y = 3'b011;
          valid = 1'b1;        
        end
        8'b000001??:begin
          y = 3'b010;
          valid = 1'b1;        
        end
        8'b0000001?:begin
          y = 3'b001;
          valid = 1'b1;        
        end
        8'b00000001:begin
          y = 3'b000;
          valid = 1'b1;        
        end
        default:begin
          y = 3'b000;
          valid = 1'b0;
        end
      endcase
    end
    else begin
      y = 3'b000;
      valid = 1'b0;
    end
  end
endmodule
