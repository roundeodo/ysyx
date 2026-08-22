module riscv32_arch_regfile
  import riscv32_pkg::*;
(
    input logic clk_i,
    input logic rst_ni,

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

  // 正沿寄存提交端口，切断“组合读 -> 执行/提交 -> 透明写”的反馈路径。payload在
  // write_enable=0时没有语义，因此只有使能位需要复位。
  xlen_data_t    staged_write_data_q;
  arch_reg_idx_t staged_write_addr_q;
  logic          staged_write_enable_q;

  always_ff @(posedge clk_i) begin
    staged_write_data_q <= gpr_write_data_i;
    staged_write_addr_q <= gpr_write_addr_i;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      staged_write_enable_q <= 1'b0;
    end else begin
      staged_write_enable_q <= gpr_write_enable_i && (gpr_write_addr_i != '0);
    end
  end

  // 小容量多端口寄存器堆采用低电平透明锁存阵列，而不是为每一位实例化正沿DFF。
  // 提交结果先在上升沿进入staged_write_*寄存器，再在随后低电平阶段写入阵列，并在
  // 下一上升沿前关闭。这个组织保持原有两读一写架构接口，避免透明期间形成组合反馈，
  // 同时更接近真实寄存器堆的面积实现。它建立了一条明确的半周期写入时序；未来流水化
  // 后可由commit级寄存器直接承担staging职责，避免重复寄存。
  always_latch begin
    if (!clk_i && staged_write_enable_q) begin
      gpr_q[staged_write_addr_q] = staged_write_data_q;
    end
  end

  assign rs1_data_o = (rs1_addr_i == '0) ? '0 : gpr_q[rs1_addr_i];
  assign rs2_data_o = (rs2_addr_i == '0) ? '0 : gpr_q[rs2_addr_i];

  // This is the RV32I architectural x0-x31 register file. NOTE(P6): rename
  // introduces a separate multi-port physical register file, RAT, RRAT, and free list.

endmodule
