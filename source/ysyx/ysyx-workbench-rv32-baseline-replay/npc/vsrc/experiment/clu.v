module clu(
    input [3:0] p,
    input [3:0] g,
    input c0,
    output [4:1] c
);
    assign c[1] = g[0] | (p[0] & c0);

    assign c[2] = g[1] | (p[1] & g[0]) | (p[1] & p[0] & c0);

    assign c[3] = g[2] | (p[2] & g[1]) | (p[2] & p[1] & g[0]) | (p[2] & p[1] & p[0] & c0);

    assign c[4] = g[3] | (p[3] & g[2]) | (p[3] & p[2] & g[1]) | (p[3] & p[2] & p[1] & g[0]) | (p[3] & p[2] & p[1] & p[0] & c0);

endmodule
