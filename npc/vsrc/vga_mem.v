module vga_mem(
    input clk,
    input [18:0] addr,       
    output reg [11:0] data   
);
    reg [11:0] ram [307199:0];

    initial begin
        $readmemh("/home/yong/Downloads/picture.hex", ram);
    end

    always @(posedge clk) begin
        data <= ram[addr];
    end
endmodule
