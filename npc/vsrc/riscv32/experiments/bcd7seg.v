// 独立组合译码实验：十六进制 0..F 转为低有效七段码，无寄存器。
// 保留历史模块名 bcd7seg；实际输入范围不局限于十进制 BCD。
module bcd7seg (
    input      [3:0] digit_i,
    output reg [6:0] segments_o
);
    always @(*) begin
        case (digit_i)
            4'h0: segments_o = 7'b1000000;
            4'h1: segments_o = 7'b1111001;
            4'h2: segments_o = 7'b0100100;
            4'h3: segments_o = 7'b0110000;
            4'h4: segments_o = 7'b0011001;
            4'h5: segments_o = 7'b0010010;
            4'h6: segments_o = 7'b0000010;
            4'h7: segments_o = 7'b1111000;
            4'h8: segments_o = 7'b0000000;
            4'h9: segments_o = 7'b0010000;
            4'hA: segments_o = 7'b0001000;
            4'hB: segments_o = 7'b0000011;
            4'hC: segments_o = 7'b1000110;
            4'hD: segments_o = 7'b0100001;
            4'hE: segments_o = 7'b0000110;
            4'hF: segments_o = 7'b0001110;
            default: segments_o = 7'b1111111;
        endcase
    end
endmodule
