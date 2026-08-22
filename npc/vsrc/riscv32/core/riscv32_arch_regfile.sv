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
  // x0的架构值恒为0且永远不能写，因此物理阵列只保存x1..x31。若把x0声明在阵列中，
  // 部分综合流程仍会为它生成一整组永远不可写的触发器和读选择逻辑。
  // 这仍是完整RV32I寄存器堆，不是RV32E；端口索引仍覆盖全部32个架构寄存器。
  xlen_data_t gpr_q[1:ARCH_REG_COUNT-1];

  // 小容量多端口寄存器堆采用低电平透明锁存阵列，而不是为每一位实例化正沿DFF。
  // 提交结果在时钟低电平期间写入，锁存器在下一上升沿前关闭；随后组合读口向下一条
  // 指令提供稳定数据。这个组织保持原有两读一写架构接口，同时更接近真实寄存器堆的
  // 面积实现。它也明确建立半周期写入时序：写地址、写数据和写使能必须在低电平阶段
  // 稳定，未来流水化后应由commit级寄存器驱动这些信号。
  always_latch begin
    if (!clk_i && gpr_write_enable_i && (gpr_write_addr_i != '0)) begin
      gpr_q[gpr_write_addr_i] <= gpr_write_data_i;
    end
  end

  assign rs1_data_o = (rs1_addr_i == '0) ? '0 : gpr_q[rs1_addr_i];
  assign rs2_data_o = (rs2_addr_i == '0) ? '0 : gpr_q[rs2_addr_i];

  // This is the RV32I architectural x0-x31 register file. NOTE(P6): rename
  // introduces a separate multi-port physical register file, RAT, RRAT, and free list.

endmodule
