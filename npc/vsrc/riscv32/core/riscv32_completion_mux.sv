module riscv32_completion_mux
  import riscv32_pkg::*;
(
    /* verilator lint_off UNUSEDSIGNAL */
    input  execute_result_t exu_result_i,
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic            exu_result_valid_i,
    output logic            exu_result_ready_o,

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

  // 首版顺序流水线在LSU busy期间阻止其他指令进入EX，因此EXU和LSU completion仍然互斥。
  // 后续允许load后继续执行独立指令时，必须用带年龄信息的仲裁或ROB completion端口替代
  // 这一固定优先级mux，不能让年轻EXU结果越过较老LSU结果提交。

endmodule
