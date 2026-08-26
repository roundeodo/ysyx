// 单发射顺序核的完成仲裁与一个延后完成槽。
//
// blocking LSU等待存储层响应时，允许一条独立的非访存指令完成到deferred slot。
// 老LSU仍然优先进入WB，延后结果只能在LSU离开后进入WB，因此提交顺序、异常顺序和
// 单写回口协议均不改变。该槽只提供一个指令的延迟隐藏能力，不是ROB，也不允许多个
// 未提交结果任意完成；若收益不足，应该升级为明确的顺序完成队列，而不是继续堆槽位。
module riscv32_in_order_completion_buffer
  import riscv32_pkg::*;
(
    input logic clk_i,
    input logic rst_ni,

    input  execute_result_t exu_result_i,
    input  logic            exu_result_valid_i,
    output logic            exu_result_ready_o,

    input  writeback_result_t lsu_writeback_i,
    input  logic              lsu_writeback_valid_i,
    output logic              lsu_writeback_ready_o,

    // 该信号表示LSU中仍有一条更老的未完成指令。它为1时，EX结果不能越过LSU进入WB，
    // 但可以进入本模块的延后完成槽。
    input logic older_lsu_transaction_present_i,

    output logic deferred_completion_present_o,

    output writeback_result_t writeback_result_o,
    output logic              writeback_result_valid_o,
    input  logic              writeback_result_ready_i,

    // commit级恢复会撤销槽内尚未提交的年轻结果。
    input logic flush_i
);

  writeback_result_t exu_writeback;
  writeback_result_t deferred_completion_q;
  logic              deferred_completion_present_q;
  logic              deferred_completion_present_d;
  logic              deferred_completion_handshake;
  logic              capture_exu_completion;

  always_comb begin
    exu_writeback           = '0;
    exu_writeback.uop       = exu_result_i.uop;
    exu_writeback.result    = exu_result_i.result;
    exu_writeback.next_pc   = exu_result_i.next_pc;
    exu_writeback.csr_wdata = exu_result_i.csr_wdata;
  end

  // 输出优先级就是程序年龄顺序：老LSU、已经保存的年轻结果、当前EX结果。
  always_comb begin
    writeback_result_o       = exu_writeback;
    writeback_result_valid_o = exu_result_valid_i &&
                               !older_lsu_transaction_present_i &&
                               !deferred_completion_present_q;

    if (deferred_completion_present_q) begin
      writeback_result_o       = deferred_completion_q;
      writeback_result_valid_o = 1'b1;
    end

    if (lsu_writeback_valid_i) begin
      writeback_result_o       = lsu_writeback_i;
      writeback_result_valid_o = 1'b1;
    end
  end

  assign lsu_writeback_ready_o = writeback_result_ready_i;

  // LSU仍在等待时，EX只能写入空的延后槽；正常情况下EX直接使用WB通道。
  assign exu_result_ready_o = older_lsu_transaction_present_i ?
                              !deferred_completion_present_q && !flush_i :
                              !deferred_completion_present_q &&
                              writeback_result_ready_i &&
                              !lsu_writeback_valid_i && !flush_i;

  assign capture_exu_completion = older_lsu_transaction_present_i &&
                                  exu_result_valid_i && exu_result_ready_o;
  assign deferred_completion_handshake = deferred_completion_present_q &&
                                         !lsu_writeback_valid_i &&
                                         writeback_result_ready_i;
  assign deferred_completion_present_o = deferred_completion_present_q;

  always_comb begin
    deferred_completion_present_d = deferred_completion_present_q;

    if (deferred_completion_handshake) begin
      deferred_completion_present_d = 1'b0;
    end
    if (capture_exu_completion) begin
      deferred_completion_present_d = 1'b1;
    end
    if (flush_i) begin
      deferred_completion_present_d = 1'b0;
    end
  end

  always_ff @(posedge clk_i) begin
    if (capture_exu_completion) begin
      deferred_completion_q <= exu_writeback;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      deferred_completion_present_q <= 1'b0;
    end else begin
      deferred_completion_present_q <= deferred_completion_present_d;
    end
  end

`ifndef SYNTHESIS
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    deferred_completion_present_q && !deferred_completion_handshake && !flush_i
    |=> (deferred_completion_present_q && $stable(deferred_completion_q)))
  else $error("deferred completion changed before ordered writeback");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    older_lsu_transaction_present_i && exu_result_valid_i &&
      deferred_completion_present_q |-> !exu_result_ready_o)
  else $error("completion buffer accepted more than one result behind an LSU");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    lsu_writeback_valid_i |->
      (writeback_result_valid_o && writeback_result_o == lsu_writeback_i))
  else $error("younger completion bypassed an older LSU writeback");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    flush_i |=> !deferred_completion_present_q)
  else $error("commit recovery retained a deferred younger completion");
`endif

endmodule
