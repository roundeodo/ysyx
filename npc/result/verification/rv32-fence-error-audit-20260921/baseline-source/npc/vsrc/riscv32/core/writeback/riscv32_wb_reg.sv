// Completion/WB流水级寄存器。EXU和LSU通过顺序completion mux共享单个写回口；
// 本模块把完成结果与提交组合逻辑隔开，并在提交级恢复时用valid-only squash取消
// 同拍到达的年轻结果。
module riscv32_wb_reg
  import riscv32_pkg::*;
(
    input  logic clk_i,
    input  logic rst_ni,

    input  writeback_result_t completion_result_i,
    input  logic              completion_result_valid_i,
    output logic              completion_result_ready_o,

    output writeback_result_t writeback_result_o,
    output logic              writeback_result_valid_o,
    input  logic              writeback_result_ready_i,

    // commit级redirect说明当前WB指令可以在本周期提交，但所有同时到达的年轻completion
    // 都必须被丢弃。flush不会取消当前writeback_result_o，只控制下一拍保存的内容。
    input  logic flush_i
);

  writeback_result_t writeback_result_q;
  logic              writeback_result_valid_q;
  logic              writeback_result_valid_d;
  logic              stage_can_accept;

  assign stage_can_accept = !writeback_result_valid_q || writeback_result_ready_i;

  // ready只表达WB寄存级是否有容量，不能混入恢复控制。flush拍即使物理采样了年轻
  // payload，writeback_result_valid_d也会被清零，因而该payload没有架构含义。
  assign completion_result_ready_o = stage_can_accept;
  assign writeback_result_o        = writeback_result_q;
  assign writeback_result_valid_o  = writeback_result_valid_q;

  always_comb begin
    writeback_result_valid_d = writeback_result_valid_q;

    if (stage_can_accept) begin
      writeback_result_valid_d = completion_result_valid_i;
    end

    if (flush_i) begin
      writeback_result_valid_d = 1'b0;
    end
  end

  always_ff @(posedge clk_i) begin
    if (completion_result_valid_i && completion_result_ready_o) begin
      writeback_result_q <= completion_result_i;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      writeback_result_valid_q <= 1'b0;
    end else begin
      writeback_result_valid_q <= writeback_result_valid_d;
    end
  end

`ifndef SYNTHESIS
  /* verilator lint_off SYNCASYNCNET */
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (writeback_result_valid_o && !writeback_result_ready_i && !flush_i)
    |=> (writeback_result_valid_o && $stable(writeback_result_o)))
  else
    $error("WB stage changed payload while backpressured");

  assert property (@(posedge clk_i) disable iff (!rst_ni) flush_i |=> !writeback_result_valid_o)
  else
    $error("WB stage retained a younger completion after commit redirect");
  /* verilator lint_on SYNCASYNCNET */
`endif

endmodule
