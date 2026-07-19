// Minimal module for observing how a variable left shift is synthesized.
// This file is intentionally independent from the CPU RTL.
module shl4_for_sta (
    input  logic [3:0] in,
    input  logic [1:0] shamt,
    output logic [3:0] out
);

  assign out = in << shamt;

endmodule
