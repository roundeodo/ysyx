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
    wire [WIDTH - 1:0] t_no_Cin;

    assign t_no_Cin = b ^{WIDTH{sub}};
    cla #(.WIDTH(WIDTH)) cla_adder(
        .a(a),
        .b(t_no_Cin),
        .cin(sub),
        .s(result),
        .cout(cout)
    );
    assign negtive_flag = result[WIDTH-1];
    assign zero_flag = ~(|result);
    assign overflow_flag = (a[WIDTH-1] == t_no_Cin[WIDTH-1]) && (result[WIDTH-1] != a[WIDTH-1]);
endmodule
