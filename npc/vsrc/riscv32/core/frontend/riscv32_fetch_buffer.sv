// IFU响应与IDU消费之间的小型弹性队列。
//
// 本模块只保存已经完成的fetch entry并吸收短暂的译码反压，不参与PC选择、cache命中、
// 分支恢复或指令译码。队列采用寄存式输出，不提供空队列组合穿透：这样可以切断
// I-cache响应到IDU冒险判断再返回前端ready的长组合路径，同时仍能在稳态每拍入队和出队。
module riscv32_fetch_buffer
  import riscv32_pkg::*;
(
    input logic clk_i,
    input logic rst_ni,

    input  fetch_entry_t ifu_fetch_entry_i,
    input  logic         ifu_fetch_entry_valid_i,
    output logic         ifu_fetch_entry_ready_o,

    output fetch_entry_t idu_fetch_entry_o,
    output logic         idu_fetch_entry_valid_o,
    input  logic         idu_fetch_entry_ready_i,

    // redirect会使队列中所有顺序取回的年轻指令失效。flush当拍拒绝新entry，时钟沿清空。
    input logic flush_i
);

  fetch_entry_t primary_entry_q;
  fetch_entry_t reserve_entry_q;
  logic         primary_entry_present_q;
  logic         reserve_entry_present_q;
  logic ifu_fetch_entry_handshake_occurred;
  logic idu_fetch_entry_handshake_occurred;

  // 两项容量固定实现为主槽和备用槽，而不是环形数组。输出直接来自主槽，避免读指针
  // 经过大宽度数组选择器后再进入IDU译码；这是前端达到高频所需的明确时序边界。
  // 入口ready只依赖寄存的备用槽状态，不依赖本拍IDU是否出队。这样EX级冒险判断不会经
  // IDU ready、队列出队条件和IFU response握手一路反馈到下一取指PC。
  // flush不能组合压低当前输出valid，但必须压低入口ready：ready/valid一旦同时为1就表示
  // sink已经接收该entry，不能在时钟沿悄悄丢弃。core只把寄存后的redirect接到这里，
  // 因而flush不会把EX/commit组合路径重新接入前端ready。
  always_comb begin
    idu_fetch_entry_o       = primary_entry_q;
    idu_fetch_entry_valid_o = primary_entry_present_q;
    ifu_fetch_entry_ready_o = !reserve_entry_present_q && !flush_i;

    ifu_fetch_entry_handshake_occurred = ifu_fetch_entry_valid_i && ifu_fetch_entry_ready_o;
    idu_fetch_entry_handshake_occurred = idu_fetch_entry_valid_o && idu_fetch_entry_ready_i;
  end

  // 主槽被消费时，备用项优先前移；若没有备用项，则同拍新输入直接接替主槽。
  // 未消费主槽时，新输入依次占用空主槽或备用槽。两个present位单独承载有效性，
  // payload无需复位，flush也不进入宽数据寄存器的写入选择路径。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      primary_entry_present_q <= 1'b0;
      reserve_entry_present_q <= 1'b0;
    end else if (flush_i) begin
      primary_entry_present_q <= 1'b0;
      reserve_entry_present_q <= 1'b0;
    end else if (idu_fetch_entry_handshake_occurred) begin
      if (reserve_entry_present_q) begin
        primary_entry_q         <= reserve_entry_q;
        primary_entry_present_q <= 1'b1;
        reserve_entry_present_q <= 1'b0;
      end else if (ifu_fetch_entry_handshake_occurred) begin
        primary_entry_q         <= ifu_fetch_entry_i;
        primary_entry_present_q <= 1'b1;
      end else begin
        primary_entry_present_q <= 1'b0;
      end
    end else if (ifu_fetch_entry_handshake_occurred) begin
      if (!primary_entry_present_q) begin
        primary_entry_q         <= ifu_fetch_entry_i;
        primary_entry_present_q <= 1'b1;
      end else begin
        reserve_entry_q         <= ifu_fetch_entry_i;
        reserve_entry_present_q <= 1'b1;
      end
    end
  end

`ifndef SYNTHESIS
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    reserve_entry_present_q |-> primary_entry_present_q)
  else $error("fetch buffer reserve entry became present without a primary entry");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (idu_fetch_entry_valid_o && !idu_fetch_entry_ready_i && !flush_i)
    |=> (flush_i || (idu_fetch_entry_valid_o && $stable(idu_fetch_entry_o))))
  else $error("fetch buffer output changed while IDU applied backpressure");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    flush_i |=> (!primary_entry_present_q && !reserve_entry_present_q))
  else $error("fetch buffer was not empty after flush");
`endif

endmodule
