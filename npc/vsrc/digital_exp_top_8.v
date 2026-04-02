module top(
    input clk,
    input rst,
    output VGA_HSYNC,
    output VGA_VSYNC,
    output VGA_BLANK_N,
    output [7:0] VGA_R,
    output [7:0] VGA_G,
    output [7:0] VGA_B,
    output flag
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

    vga_ctrl vga_ctrl_inst(
        .pclk(clk),
        .reset(rst),
        .vga_data(vga_data_24bit),
        .h_addr(h_addr),
        .v_addr(v_addr),
        .hsync(VGA_HSYNC),
        .vsync(VGA_VSYNC),
        .valid(VGA_BLANK_N),
        .vga_r(VGA_R),
        .vga_g(VGA_G),
        .vga_b(VGA_B)
    );

    vga_mem vga_mem_inst(
        .h_addr(h_addr),
        .v_addr(v_addr[8:0]),
        .vga_data(vga_data_24bit)
    );

    assign flag = v_addr[9];

    
endmodule
