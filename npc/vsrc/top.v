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

    vga_ctrl cga_ctrl_inst(
        .pclk(vga_clk),
        .reset(rst),
        .vga_data(vga_data_24bit),
        .h_addr(h_addr),
        .v_addr(v_addr),
        .hsync(VGA_HSYNC),
        .vsync(VGA_VSYNC),
        .valid(vga_valid),
        .vga_r(VGA_R),
        .vga_g(VGA_G),
        .vga_b(VGA_B)
    );
    assign VGA_BLANK_N = vga_valid;
    wire [18:0] rom_addr;
    assign rom_addr =  v_addr*640 + h_addr;
    wire [11:0] rom_data_12bit;

    vga_mem vga_mem_inst(
        .clk(vga_clk),
        .addr(rom_addr),
        .data(rom_data_12bit)   
    );

    assign vga_data_24bit = {rom_data_12bit[11:8],4'b0,rom_data_12bit[7:4],4'b0,rom_data_12bit[3:0],4'b0};

    
endmodule
