module compound_adder#(parameter WIDTH = 4)(
    input [WIDTH - 1:0] a,
    input [WIDTH - 1:0] b,
    input sub,
    output overflow_flag,
    output zero_flag,
    output negtive_flag,
    output cout,
    output [WIDTH - 1:0]result
);
    wire [WIDTH - 1:0] b_ones_complement;

    assign b_ones_complement = b ^{WIDTH{sub}};
    cla #(.WIDTH(WIDTH)) cla_adder(
        .a(a),
        .b(b_ones_complement),
        .cin(sub),
        .s(result),
        .cout(cout)
    );
    assign negtive_flag = result[WIDTH-1];
    assign zero_flag = ~(|result);
    assign overflow_flag = (a[WIDTH-1] == b_ones_complement[WIDTH-1]) && (result[WIDTH-1] != a[WIDTH-1]);
endmodule
