module clkgen(
    input clkin,
    input rst,
    input clken,
    output reg clkout
);
    parameter clk_freq = 25000000;
    // 计算触发翻转的阈值。对于二分频（50M -> 25M），阈值应为 0
    parameter countlimit = (50000000 / (2 * clk_freq)) - 1;

    reg [31:0] clkcount;

    always @ (posedge clkin) begin
        if (rst) begin
            clkcount <= 32'd0;
            // 关键：复位时不要给 clkout 固定值，或者仅给初始值，允许其受 clken 驱动
        end
        else if (clken) begin
            if (clkcount >= countlimit) begin
                clkcount <= 32'd0;
                clkout   <= ~clkout;
            end
            else begin
                clkcount <= clkcount + 32'd1;
            end
        end
    end
endmodule
