module riscv32_completion_mux
  import riscv32_pkg::*;
(
    /* verilator lint_off UNUSEDSIGNAL */
    input  execute_result_t exu_result_i,
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic exu_result_valid_i,
    output logic exu_result_ready_o,

    input  writeback_result_t lsu_writeback_i,
    input  logic              lsu_writeback_valid_i,
    output logic              lsu_writeback_ready_o,

    output writeback_result_t writeback_result_o,
    output logic              writeback_result_valid_o,
    input  logic              writeback_result_ready_i
);
  writeback_result_t exu_writeback;

  always_comb begin
    exu_writeback           = '0;
    exu_writeback.uop       = exu_result_i.uop;
    exu_writeback.result    = exu_result_i.result;
    exu_writeback.next_pc   = exu_result_i.next_pc;
    exu_writeback.csr_wdata = exu_result_i.csr_wdata;
  end

  always_comb begin
    writeback_result_o       = exu_writeback;
    writeback_result_valid_o = exu_result_valid_i;

    if (lsu_writeback_valid_i) begin
      writeback_result_o       = lsu_writeback_i;
      writeback_result_valid_o = 1'b1;
    end
  end

  assign lsu_writeback_ready_o = writeback_result_ready_i;
  assign exu_result_ready_o    = writeback_result_ready_i && !lsu_writeback_valid_i;

  // 老 LSU 的完成优先占用 WB，普通 EX 的 ready=0，由 ID/EX 保持当前指令。
  // 旧结果级配置可先保存年轻普通结果，但仍须等待老 LSU 交付，不能越序提交。
  // 年龄约束由 hazard_ctrl 保证；允许独立年轻指令越过长延迟事务需要顺序完成队列或 ROB。

endmodule
