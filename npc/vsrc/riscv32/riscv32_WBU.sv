module riscv32_WBU
  import riscv32_pkg::*;
#(
    parameter DATA_WIDTH = 32,
    parameter ADDR_WIDTH = 5
) (
    // data from LSU
    // WBU consumes LSU completion/result record directly.
    // writeback/bypass/ROB writeback 都应该消费 result record，而不是 top 拆线。
    input lsu_result_t                  i_wbu_lsu_result,
    input logic        [DATA_WIDTH-1:0] i_wbu_csr_rdata,

    // to RF
    output logic [DATA_WIDTH-1:0] o_wbu_wdata,
    output logic [ADDR_WIDTH-1:0] o_wbu_waddr,
    output logic                  o_wbu_wen
);
  // ==========================================================================
  // WBU design boundary
  // ==========================================================================
  //
  // WBU 的当前职责是 writeback data select + RegisterFile write port driving。
  // 它不应该判断 opcode，也不应该知道当前是 lw、jal 还是 add。
  //
  // 高性能 CPU 关联：
  //   当前单周期 WBU 是 architectural state update 的最后边界。
  //   未来乱序 CPU 中，“执行完成”和“架构提交”会分离：
  //     execute/writeback -> 写 physical register
  //     commit/retire     -> 按程序顺序更新 architectural state
  //   现在把 WBU 边界划清楚，是理解 ROB/precise exception 的前提。
  //
  // WBU write enable must only reflect architectural writeback.
  // o_wbu_wen 应该只在真正需要写 architectural register 时有效。
  //
  // 不应该写：
  //   store / branch / fence / ebreak / illegal instruction
  //
  // 这些应该由 Decoder 的 reg_wen 决定，WBU 不要自己 decode opcode。
  //
  // x0 保护：
  //   RegisterFile 必须屏蔽 x0 写入。
  //   WBU 也额外做一层 valid/rd 保护：
  //     o_wbu_wen = i_wbu_lsu_result.valid &&
  //                 i_wbu_lsu_result.reg_wen &&
  //                 (i_wbu_lsu_result.rd_addr != '0);
  //
  // 高性能 CPU 关联：
  //   precise state 的核心原则是：只有 commit 的指令才能修改 architectural state。
  //   当前单周期没有 ROB，但 reg_wen 的语义必须先干净。
  //
  // Keep WBU narrow. WBU 不要加入：
  //   opcode 判断
  //   load sign extension
  //   branch/jump 判断
  //   illegal instruction 判断
  //
  // load formatting 属于 LSU，control legality 属于 Decoder，redirect 属于 EXU/IFU。
  // WBU 只选择写回数据并驱动 RF 写端口。

  always_comb begin
    case (i_wbu_lsu_result.wb_sel)
      WB_ALU_RES: o_wbu_wdata = i_wbu_lsu_result.alu_res;
      WB_MEM_RES: o_wbu_wdata = i_wbu_lsu_result.mem_rdata;
      WB_PC4:     o_wbu_wdata = i_wbu_lsu_result.pc_plus_4;
      WB_CSR:     o_wbu_wdata = i_wbu_csr_rdata;
      default:    o_wbu_wdata = {DATA_WIDTH{1'b0}};
    endcase
  end

  // 当前单周期没有 commit 阶段，但 WBU 已经是 architectural state update 边界。
  // 以后乱序 CPU 会把这个语义移动到 commit/retire。
  assign o_wbu_waddr = i_wbu_lsu_result.rd_addr;
  assign o_wbu_wen   = i_wbu_lsu_result.valid && i_wbu_lsu_result.reg_wen && (i_wbu_lsu_result.rd_addr != '0);

endmodule
