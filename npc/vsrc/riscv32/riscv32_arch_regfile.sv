module riscv32_arch_regfile
  import riscv32_pkg::*;
(
    input logic clk_i,

    input logic          [XLEN-1:0] write_data_i,
    input arch_reg_idx_t            write_addr_i,
    input logic                     write_enable_i,

    input  arch_reg_idx_t            read_addr_a_i,
    output logic          [XLEN-1:0] read_data_a_o,
    input  arch_reg_idx_t            read_addr_b_i,
    output logic          [XLEN-1:0] read_data_b_o
);
  logic [XLEN-1:0] rf[ARCH_REG_NUM-1:0];

  always_ff @(posedge clk_i) begin
    if (write_enable_i && (write_addr_i != '0)) begin
      rf[write_addr_i] <= write_data_i;
    end
  end

  assign read_data_a_o = (read_addr_a_i == '0) ? '0 : rf[read_addr_a_i];
  assign read_data_b_o = (read_addr_b_i == '0) ? '0 : rf[read_addr_b_i];

  // This is the RV32I architectural x0-x31 register file. NOTE(P6): rename
  // introduces a separate multi-port physical register file, RAT, RRAT, and free list.

endmodule
