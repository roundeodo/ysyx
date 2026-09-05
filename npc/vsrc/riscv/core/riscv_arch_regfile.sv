// 保存 x1～x31，读取 x0 时返回零。
module riscv_arch_regfile
  import riscv_pkg::*;
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
  // 当前为 RV64I 架构寄存器堆，端口索引覆盖 x0～x31，数据宽度由 XLEN 定义。
  xlen_data_t gpr_array_q[1:ARCH_REG_COUNT-1];

  // 架构提交和寄存器堆写入发生在同一个上升沿。提交事件被仿真器或Difftest观察到时，
  // gpr_array_q必须已经反映该条指令的架构结果，不能再延迟到下降半周期。组合读口使下一拍
  // 寄存器读取级使用数据；尚未提交的依赖结果由流水线前递网络提供。
  // 寄存器内容无需复位，软件在读取前负责初始化；x0不在物理阵列中。
  always_ff @(posedge clk_i) begin
    if (gpr_write_enable_i && (gpr_write_addr_i != '0)) begin
      gpr_array_q[gpr_write_addr_i] <= gpr_write_data_i;
    end
  end

  assign rs1_data_o = (rs1_addr_i == '0) ? '0 : gpr_array_q[rs1_addr_i];
  assign rs2_data_o = (rs2_addr_i == '0) ? '0 : gpr_array_q[rs2_addr_i];

  // M2 将另行实现物理寄存器堆、重命名映射和空闲表，不能只扩大本架构寄存器数组。

endmodule
