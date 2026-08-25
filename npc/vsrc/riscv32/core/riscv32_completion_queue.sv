// 顺序流水线的完成仲裁与单项年轻结果缓冲。
//
// LSU事务比当前EX指令更老。LSU等待存储响应期间，本模块允许一条已经完成的年轻EX结果
// 进入缓冲；老LSU完成后仍优先进入WB，下一拍再交付缓冲结果。这样可以隐藏D-cache一拍
// 命中的固定流水气泡，又不会让年轻结果越过老访存。若需要保存多条结果或允许乱序完成，
// 必须使用带年龄信息的completion queue或ROB，而不能继续扩大这个单项缓冲。
module riscv32_completion_queue
  import riscv32_pkg::*;
(
    input logic clk_i,
    input logic rst_ni,

    /* verilator lint_off UNUSEDSIGNAL */
    input  execute_result_t exu_result_i,
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic            exu_result_valid_i,
    output logic            exu_result_ready_o,

    input  writeback_result_t lsu_writeback_i,
    input  logic              lsu_writeback_valid_i,
    output logic              lsu_writeback_ready_o,

    // 该信号为1时，LSU结果的年龄早于当前EX结果；它决定同拍两项完成的提交顺序。
    input logic older_lsu_transaction_active_i,

    output execute_result_t buffered_exu_result_o,
    output logic            buffered_exu_result_present_o,

    output writeback_result_t writeback_result_o,
    output logic              writeback_result_valid_o,
    input  logic              writeback_result_ready_i,

    // 提交级trap/mret/fence.i会删除所有尚未进入WB的年轻结果。
    input logic flush_i
);

  writeback_result_t exu_writeback;
  writeback_result_t buffered_exu_writeback;
  execute_result_t   buffered_exu_result_q;
  logic              buffered_exu_result_present_q;
  logic              buffered_exu_result_selected;
  logic              lsu_writeback_selected;
  logic              exu_direct_path_selected;
  logic              buffered_exu_result_handshake;
  logic              exu_result_handshake;
  logic              exu_result_requires_buffer;

  always_comb begin
    exu_writeback           = '0;
    exu_writeback.uop       = exu_result_i.uop;
    exu_writeback.result    = exu_result_i.result;
    exu_writeback.next_pc   = exu_result_i.next_pc;
    exu_writeback.csr_wdata = exu_result_i.csr_wdata;

    // 缓冲槽只保存EX真正产生的字段。memory_addr/rdata/wdata/wmask属于LSU完成信息，
    // 若把完整writeback_result_t存进该槽，会为永远无效的字段生成额外触发器。
    buffered_exu_writeback           = '0;
    buffered_exu_writeback.uop       = buffered_exu_result_q.uop;
    buffered_exu_writeback.result    = buffered_exu_result_q.result;
    buffered_exu_writeback.next_pc   = buffered_exu_result_q.next_pc;
    buffered_exu_writeback.csr_wdata = buffered_exu_result_q.csr_wdata;
  end

  // 如果LSU仍是更老的在途指令，它的completion具有最高优先级。LSU已经不再属于
  // 更老事务时，缓冲项的年龄早于新到达的LSU结果，必须先交付缓冲项。
  assign lsu_writeback_selected = lsu_writeback_valid_i &&
                                  (older_lsu_transaction_active_i ||
                                   !buffered_exu_result_present_q);
  assign buffered_exu_result_selected = buffered_exu_result_present_q &&
                                        !lsu_writeback_selected &&
                                        !older_lsu_transaction_active_i;
  assign exu_direct_path_selected = !lsu_writeback_selected &&
                                    !buffered_exu_result_present_q &&
                                    !older_lsu_transaction_active_i;

  always_comb begin
    writeback_result_o       = exu_writeback;
    writeback_result_valid_o = exu_result_valid_i && exu_direct_path_selected;

    if (buffered_exu_result_selected) begin
      writeback_result_o       = buffered_exu_writeback;
      writeback_result_valid_o = 1'b1;
    end

    if (lsu_writeback_selected) begin
      writeback_result_o       = lsu_writeback_i;
      writeback_result_valid_o = 1'b1;
    end
  end

  // 老LSU响应可以直接进入WB。年轻LSU若遇到尚未交付的缓冲项，则必须等待，避免
  // completion固定优先级破坏程序顺序。
  assign lsu_writeback_ready_o = writeback_result_ready_i &&
                                 (older_lsu_transaction_active_i ||
                                  !buffered_exu_result_present_q);

  // 缓冲为空时可吸收一条年轻EX结果，即使老LSU本拍尚未返回；缓冲项本拍成功离开时，
  // 也允许用当前EX结果同拍替换，实现无空拍的pop/push。
  assign exu_result_ready_o = !flush_i &&
                              (exu_direct_path_selected ? writeback_result_ready_i :
                               (!buffered_exu_result_present_q ||
                                (buffered_exu_result_selected && writeback_result_ready_i)));

  assign buffered_exu_result_handshake = buffered_exu_result_selected &&
                                         writeback_result_ready_i;
  assign exu_result_handshake = exu_result_valid_i && exu_result_ready_o;
  assign exu_result_requires_buffer = exu_result_handshake && !exu_direct_path_selected;

  assign buffered_exu_result_o         = buffered_exu_result_q;
  assign buffered_exu_result_present_o = buffered_exu_result_present_q;

  always_ff @(posedge clk_i) begin
    if (exu_result_requires_buffer) begin
      buffered_exu_result_q <= exu_result_i;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      buffered_exu_result_present_q <= 1'b0;
    end else if (flush_i) begin
      buffered_exu_result_present_q <= 1'b0;
    end else begin
      unique case ({exu_result_requires_buffer, buffered_exu_result_handshake})
        2'b10: buffered_exu_result_present_q <= 1'b1;
        2'b01: buffered_exu_result_present_q <= 1'b0;
        // 2'b11是同拍pop/push，槽位继续有效并在上面的payload寄存器中换入新结果。
        default: buffered_exu_result_present_q <= buffered_exu_result_present_q;
      endcase
    end
  end

`ifndef SYNTHESIS
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    buffered_exu_result_present_q && !buffered_exu_result_handshake && !flush_i
    |=> buffered_exu_result_present_q && $stable(buffered_exu_result_q))
  else $error("completion queue changed a buffered EX result before delivery");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    older_lsu_transaction_active_i && lsu_writeback_valid_i &&
    buffered_exu_result_present_q |-> lsu_writeback_selected)
  else $error("completion queue allowed a young EX result to pass an older LSU completion");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    buffered_exu_result_present_q && !older_lsu_transaction_active_i &&
    lsu_writeback_valid_i |-> !lsu_writeback_ready_o)
  else $error("completion queue allowed a young LSU completion to pass an older buffered EX result");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    flush_i |=> !buffered_exu_result_present_q)
  else $error("completion queue retained a young result after commit recovery");
`endif

endmodule
