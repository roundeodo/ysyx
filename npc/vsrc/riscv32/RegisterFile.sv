// TODO(HP-RF-0): 当前顺序核阶段将文件和模块重命名为 riscv32_arch_regfile。
// “RegisterFile”无法区分 architectural register file 与未来 physical register file；进入 rename
// 阶段后保留 riscv32_phys_regfile，不要让两个不同语义的模块继续共享泛化名称。
// TODO(HP-RF-1): 当前模块是 ArchitecturalRegisterFile，不是未来乱序核的 PRF。
// 完成 in-order riscv32_commit 后先把写端口改成 commit 驱动；进入 rename 阶段时另外创建
// RAT、RRAT/committed map、FreeList 和 PhysicalRegisterFile，不要把这些职责塞进本模块。
module RegisterFile #(
    parameter ADDR_WIDTH = 5,
    parameter DATA_WIDTH = 32
) (
    input logic clk,

    // write port
    input logic [DATA_WIDTH-1:0] i_RF_wdata,
    input logic [ADDR_WIDTH-1:0] i_RF_waddr,
    input logic                  i_RF_wen,

    // read port 1
    input  logic [ADDR_WIDTH-1:0] i_RF_raddr1,
    output logic [DATA_WIDTH-1:0] o_RF_rdata1,

    // read port 2
    input  logic [ADDR_WIDTH-1:0] i_RF_raddr2,
    output logic [DATA_WIDTH-1:0] o_RF_rdata2
);
  // ==========================================================================
  // RegisterFile design boundary
  // ==========================================================================
  //
  // 当前 RegisterFile 是 RV32I architectural register file，实现 x0-x31。
  //
  // 高性能 CPU 关联：
  //   未来乱序 CPU 会把 architectural register namespace 和 physical register file 分开：
  //     logical register  -> rename map -> physical register
  //     ROB commit        -> architectural state update
  //
  //   当前阶段先不要实现 rename/ROB/PRF，但必须保持 architectural register 语义正确。
  //
  // RV32I register-count boundary:
  //   ADDR_WIDTH=5 例化 32 个架构寄存器，所有 5-bit register specifier 都合法。
  //   后续不要用缩小 ARF 的方式实现高性能设计；rename 阶段应保持 32 项逻辑命名空间，
  //   并通过 RAT 映射到数量更多、索引更宽的 physical register file。
  //
  // x0 hardwired-zero rule:
  //   当前写端口已经屏蔽 waddr == 0，读端口也对 raddr == 0 返回 0。
  //   后续如果改内部数组大小或端口类型，必须保持这个语义。
  //
  //   WBU 也可以额外屏蔽 rd == 0，但 RF 必须作为最后防线。
  //
  // Read/write timing before pipeline:
  //   当前是组合读、时钟沿写，适合单周期。
  //
  //   后续五级流水要明确：
  //     同周期读写同一寄存器时读旧值还是新值
  //     是否需要 forwarding
  //     writeback 在周期前半还是后半生效
  //
  //   高性能 CPU 关联：
  //     这些时序规则会影响 bypass network、scoreboard ready bit、issue wakeup。
  //
  // Physical-register-file boundary:
  //   当前不要急着做：
  //     physical register file
  //     rename map table
  //     free list
  //     ROB commit map
  //
  //   先保证 architectural x0-x31 行为正确。等单周期和顺序流水线稳定后，再引入 rename。

  // TODO(HP-RF-2): 创建 PhysicalRegisterFile 时重新设计端口数量，而不是复制当前 2R1W 接口。
  // 读端口数由 issue width 和执行单元决定，写端口数由 completion bandwidth 决定；同时需要
  // ready bits、wakeup/bypass 冲突规则和多写端口仲裁。当前 rf 只保留到 rename 接入完成。
  logic [DATA_WIDTH-1:0] rf[2**ADDR_WIDTH-1:0];

  // TODO(HP-RF-3): 在当前顺序核阶段，把 i_RF_wen 明确接到 riscv32_commit 的 commit_reg_wen。
  // 这样即使暂时没有 ROB，也能保证异常指令和被 flush 指令不会提前修改架构寄存器。
  always_ff @(posedge clk) begin
    if (i_RF_wen && (i_RF_waddr != {ADDR_WIDTH{1'b0}})) begin
      rf[i_RF_waddr] <= i_RF_wdata;
    end
  end

  assign o_RF_rdata1 = (i_RF_raddr1 == {ADDR_WIDTH{1'b0}}) ? {DATA_WIDTH{1'b0}} : rf[i_RF_raddr1];
  assign o_RF_rdata2 = (i_RF_raddr2 == {ADDR_WIDTH{1'b0}}) ? {DATA_WIDTH{1'b0}} : rf[i_RF_raddr2];

endmodule
