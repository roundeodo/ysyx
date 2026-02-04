module top(
    input clk,
    input rst,
    output VGA_HSYNC,
    output VGA_VSYNC,
    output VGA_BLANK_N,
    output [7:0] VGA_R,
    output [7:0] VGA_G,
    output [7:0] VGA_B
);

wire hsync_raw, vsync_raw, valid_raw;
wire [7:0] r_raw, g_raw, b_raw;

reg vga_hsync_reg, vga_vsync_reg, vga_valid_reg;
reg [7:0] vga_r_reg, vga_g_reg, vga_b_reg;

always @(posedge vga_clk) begin
    if (rst) begin
        vga_hsync_reg <= 1'b1;
        vga_vsync_reg <= 1'b1;
        vga_valid_reg <= 1'b0;
        vga_r_reg <= 8'h0;
        vga_g_reg <= 8'h0;
        vga_b_reg <= 8'h0;
    end else begin
        // 将控制信号延迟一拍，与 ROM 输出的数据对齐
        vga_hsync_reg <= hsync_raw;
        vga_vsync_reg <= vsync_raw;
        vga_valid_reg <= valid_raw;
        vga_r_reg <= r_raw;
        vga_g_reg <= g_raw;
        vga_b_reg <= b_raw;
    end
end

assign VGA_HSYNC = vga_hsync_reg;
assign VGA_VSYNC = vga_vsync_reg;
assign VGA_BLANK_N = vga_valid_reg;
assign VGA_R = vga_r_reg;
assign VGA_G = vga_g_reg;
assign VGA_B = vga_b_reg;

    wire vga_clk;
    clkgen#(
        .clk_freq(25000000)
    )clkgen_inst(
        .clkin(clk),
        .rst(rst),
        .clken(1'b1),
        .clkout(vga_clk)
    );

    wire [9:0] h_addr,v_addr;
    wire [23:0] vga_data_24bit;
    wire vga_valid;

    vga_ctrl vga_ctrl_inst(
        .pclk(vga_clk),
        .reset(rst),
        .vga_data(vga_data_24bit),
        .h_addr(h_addr),
        .v_addr(v_addr),
        .hsync(hsync_raw),
        .vsync(vsync_raw),
        .valid(valid_raw),
        .vga_r(r_raw),
        .vga_g(g_raw),
        .vga_b(b_raw)
    );
    assign VGA_BLANK_N = vga_valid;
    wire [18:0] rom_addr;
    assign rom_addr =  ({9'b0,v_addr} * 19'd640) + {9'b0,h_addr};
    wire [11:0] rom_data_12bit;

    vga_mem vga_mem_inst(
        .clk(vga_clk),
        .addr(rom_addr),
        .data(rom_data_12bit)   
    );

    assign vga_data_24bit = {rom_data_12bit[11:8],4'b0,rom_data_12bit[7:4],4'b0,rom_data_12bit[3:0],4'b0};

    
endmodule
