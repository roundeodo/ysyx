module riscv32_arch_regfile
  import riscv32_pkg::*;
(
    input logic clk_i,

    // 架构寄存器只保存XLEN宽数据，与物理地址、cache word和AXI beat宽度无关。
    input xlen_data_t    gpr_write_data_i,
    input arch_reg_idx_t gpr_write_addr_i,
    input logic          gpr_write_enable_i,

    input  arch_reg_idx_t rs1_addr_i,
    output xlen_data_t    rs1_data_o,
    input  arch_reg_idx_t rs2_addr_i,
    output xlen_data_t    rs2_data_o
);
  // 架构寄存器数量来自全局配置，不在本模块建立兼容别名。
  xlen_data_t gpr_q[ARCH_REG_COUNT-1:0];

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
