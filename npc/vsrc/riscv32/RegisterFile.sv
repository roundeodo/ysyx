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
  // 当前 RegisterFile 是 architectural register file。
  // RV32E 的 architectural register 只有 x0-x15，但 RISC-V 指令字段仍然是 5 bit。
  //
  // 高性能 CPU 关联：
  //   未来乱序 CPU 会把 architectural register namespace 和 physical register file 分开：
  //     logical register  -> rename map -> physical register
  //     ROB commit        -> architectural state update
  //
  //   当前阶段先不要实现 rename/ROB/PRF，但必须保持 architectural register 语义正确。
  //
  // RV32E register-count boundary:
  //   当前 ADDR_WIDTH=5 会例化 32 个寄存器。
  //   功能上可以跑，但 RV32E 最小实现更合理的边界是：
  //
  //     端口仍然接收 5-bit ISA register specifier
  //     内部只实现 ARCH_REG_NUM = 16 个 architectural register
  //
  //   注意：
  //     x16-x31 是否非法不应该由 RegisterFile 判断，因为 RF 不知道 opcode。
  //     I-type 的 instruction[24:20] 可能是 immediate/shamt，不一定是 rs2。
  //     非法寄存器检查应该由 Decoder 根据 opcode 产生 illegal metadata。
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
  //   先保证 architectural x0-x15 行为正确。等单周期和顺序流水线稳定后，再引入 rename。

  logic [DATA_WIDTH-1:0] rf[2**ADDR_WIDTH-1:0];

  always_ff @(posedge clk) begin
    if (i_RF_wen && (i_RF_waddr != {ADDR_WIDTH{1'b0}})) begin
      rf[i_RF_waddr] <= i_RF_wdata;
    end
  end

  assign o_RF_rdata1 = (i_RF_raddr1 == {ADDR_WIDTH{1'b0}}) ? {DATA_WIDTH{1'b0}} : rf[i_RF_raddr1];
  assign o_RF_rdata2 = (i_RF_raddr2 == {ADDR_WIDTH{1'b0}}) ? {DATA_WIDTH{1'b0}} : rf[i_RF_raddr2];

endmodule
