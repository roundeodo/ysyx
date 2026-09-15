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

  // 架构提交和寄存器堆写入发生在同一个上升沿。提交事件被仿真器或Difftest观察到时，
  // gpr_q必须已经反映该条指令的架构结果，不能再延迟到下降半周期。同拍进入ID/EX的
  // 消费者通过core中的WB前递取得新值；后续周期由组合读口直接读取更新后的GPR。
  // 寄存器内容无需复位，软件在读取前负责初始化；x0不在物理阵列中。
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
