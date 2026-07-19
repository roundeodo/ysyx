module riscv32_arch_regfile
  import riscv32_pkg::*;
(
    input logic clk_i,

    input logic          [XLEN-1:0] gpr_write_data_i,
    input arch_reg_idx_t            gpr_write_addr_i,
    input logic                     gpr_write_enable_i,

    input  arch_reg_idx_t            rs1_addr_i,
    output logic          [XLEN-1:0] rs1_data_o,
    input  arch_reg_idx_t            rs2_addr_i,
    output logic          [XLEN-1:0] rs2_data_o
);
  logic [XLEN-1:0] gpr_q[ARCH_REG_NUM-1:0];

  always_ff @(posedge clk_i) begin
    if (gpr_write_enable_i && (gpr_write_addr_i != '0)) begin
      gpr_q[gpr_write_addr_i] <= gpr_write_data_i;
    end
  end

  assign rs1_data_o = (rs1_addr_i == '0) ? '0 : gpr_q[rs1_addr_i];
  assign rs2_data_o = (rs2_addr_i == '0) ? '0 : gpr_q[rs2_addr_i];

  // This is the RV32I architectural x0-x31 register file. NOTE(P6): rename
  // introduces a separate multi-port physical register file, RAT, RRAT, and free list.

endmodule
