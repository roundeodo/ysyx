module alu #(parameter WIDTH = 4)(
    input [2:0]opcode,
    input [WIDTH - 1:0] alu_in_a,
    input [WIDTH - 1:0] alu_in_b,
    output alu_zero,
    output alu_overflow,
    output alu_negtive,
    output alu_carry,
    output reg [WIDTH-1:0] alu_out
);
    wire [WIDTH-1:0] adder_result;
    wire cout;
    wire zero_flag;
    wire overflow_flag;
    wire negtive_flag;
    wire sub;

    assign sub = (opcode == 3'b001) || (opcode == 3'b110) || (opcode == 3'b111);
    
    compound_adder #(.WIDTH(WIDTH)) arithmetic_unit(
        .a(alu_in_a),
        .b(alu_in_b),
        .sub(sub),
        .overflow_flag(overflow_flag),
        .negtive_flag(negtive_flag),
        .zero_flag(zero_flag),
        .result(adder_result),
        .cout(cout)
    );

    assign alu_overflow = overflow_flag;
    assign alu_negtive = negtive_flag;
    assign alu_carry = cout ^ sub;
    assign alu_zero = zero_flag;

    always @(*) begin
        case(opcode)
            3'b000: alu_out = adder_result; 
            3'b001: alu_out = adder_result; 
            3'b010: alu_out = ~alu_in_a;    
            3'b011: alu_out = alu_in_a & alu_in_b; 
            3'b100: alu_out = alu_in_a | alu_in_b; 
            3'b101: alu_out = alu_in_a ^ alu_in_b; 
            
            3'b110: alu_out = {{(WIDTH-1){1'b0}}, negtive_flag ^ overflow_flag};
            
            3'b111: alu_out = {{(WIDTH-1){1'b0}}, zero_flag};
            
            default: alu_out = {WIDTH{1'b0}};
        endcase 
    end

    
endmodule
