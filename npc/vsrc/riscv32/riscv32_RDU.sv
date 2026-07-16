module riscv32_RDU #(
    parameter DATA_WIDTH = 32
) (
    input logic                  i_ex_redirect_valid,
    input logic [DATA_WIDTH-1:0] i_ex_redirect_pc,

    input logic                  i_trap_redirect_valid,
    input logic [DATA_WIDTH-1:0] i_trap_vector_pc,

    input logic                  i_mret_redirect_valid,
    input logic [DATA_WIDTH-1:0] i_mret_pc,

    output logic                  o_redirect_valid,
    output logic [DATA_WIDTH-1:0] o_redirect_pc
);
  always_comb begin
    o_redirect_valid = i_ex_redirect_valid;
    o_redirect_pc    = i_ex_redirect_pc;

    if (i_trap_redirect_valid) begin
      o_redirect_valid = 1'b1;
      o_redirect_pc    = i_trap_vector_pc;
    end else if (i_mret_redirect_valid) begin
      o_redirect_valid = 1'b1;
      o_redirect_pc    = i_mret_pc;
    end
  end



endmodule
