module clkgen #(
    parameter clk_freq = 25000000 // 建议把参数移到 Header，方便外部修改
)(
    input clkin,
    input rst,
    input clken,
    output reg clkout
);
    // 1. 修正计算公式：目标是 25MHz，50M 输入下，每 1 个周期就该翻转一次
    // 阈值设为 (50M / (2 * freq)) - 1
    localparam COUNT_LIMIT = (50000000 / (2 * clk_freq)) - 1;

    // 2. 使用 generate 规避“弱智”警告
    generate
        if (COUNT_LIMIT <= 0) begin : gen_fast_clk
            // 分频系数为 1 的情况：直接翻转，不需要计数器，Verilator 就看不到那个比较了
            always @(posedge clkin) begin
                if (rst) 
                    clkout <= 1'b0; // 统一使用非阻塞赋值 <=
                else if (clken) 
                    clkout <= ~clkout;
            end
        end
        else begin : gen_divided_clk
            // 标准分频逻辑
            reg [31:0] clkcount;
            always @(posedge clkin) begin
                if (rst) begin
                    clkcount <= 32'd0;
                    clkout   <= 1'b0;
                end
                else if (clken) begin
                    if (clkcount >= COUNT_LIMIT[31:0]) begin
                        clkcount <= 32'd0;
                        clkout   <= ~clkout;
                    end
                    else begin
                        clkcount <= clkcount + 32'd1;
                    end
                end
            end
        end
    endgenerate
endmodule