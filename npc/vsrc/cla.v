module cla #(parameter WIDTH = 4)(
    input [WIDTH-1:0] a,
    input [WIDTH-1:0] b,
    input cin,
    output [WIDTH-1:0] s,
    output cout
);
    wire [WIDTH-1:0] p,g;
    wire [WIDTH:0] c;
    assign c[0] = cin;

    genvar i;
    generate
        for(i = 0; i < WIDTH; i = i + 1)begin
          pfa u_pfa( //partial full adder
            .a(a[i]),
            .b(b[i]),
            .cin(c[i]),
            .p(p[i]),
            .g(g[i]),
            .s(s[i])
          );
        end
    endgenerate

    clu u_clu( //carry lookahead unit
        .p(p),
        .g(g),
        .c0(cin),
        .c(c[4:1])
    );
    assign cout = c[WIDTH];
    
endmodule
