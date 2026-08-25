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

    // LSU等待response期间，当前EX指令年龄更小。即使completion口空闲，也不能让它先写回。
    input logic older_lsu_transaction_active_i,

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
    writeback_result_valid_o = exu_result_valid_i && !older_lsu_transaction_active_i;

    if (lsu_writeback_valid_i) begin
      writeback_result_o       = lsu_writeback_i;
      writeback_result_valid_o = 1'b1;
    end
  end

  assign lsu_writeback_ready_o = writeback_result_ready_i;
  assign exu_result_ready_o    = writeback_result_ready_i && !lsu_writeback_valid_i &&
                                 !older_lsu_transaction_active_i;

  // 顺序流水线允许一条年轻指令提前驻留EX，但在老LSU事务完成前不允许它离开EX。
  // 这里的年龄门控保证固定优先级mux不会让年轻结果越过老访存。若未来允许多条年轻指令
  // 独立完成，必须用带年龄的完成队列或ROB替代该标量接口。

`ifndef SYNTHESIS
  always_comb begin : check_program_order
    if (older_lsu_transaction_active_i && !lsu_writeback_valid_i) begin
      assert (!writeback_result_valid_o && !exu_result_ready_o)
      else $error("completion mux allowed a younger EXU result to pass an older LSU transaction");
    end
  end
`endif

endmodule
