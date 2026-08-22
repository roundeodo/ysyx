// IFU响应与IDU消费之间的单项fall-through弹性缓冲。
//
// 当前核心同一时刻只允许一条指令进入执行路径，前端也只有一个阻塞式I-cache miss在途，
// 因此第二个fetch entry只会增加寄存器面积，不会增加可持续吞吐。空缓冲时请求通过组合
// 旁路直接交给IDU；IDU反压时才把entry保存下来。这样既保留完整ready/valid解耦，又不会
// 为每条无反压指令固定增加一拍延迟。
module riscv32_fetch_buffer
  import riscv32_pkg::*;
(
    input logic clk_i,
    input logic rst_ni,

    // IFU作为上游生产者：entry和valid进入buffer，ready返回IFU。
    input  fetch_entry_t ifu_fetch_entry_i,
    input  logic         ifu_fetch_entry_valid_i,
    output logic         ifu_fetch_entry_ready_o,

    // IDU作为下游消费者：entry和valid离开buffer，ready由IDU返回。
    output fetch_entry_t idu_fetch_entry_o,
    output logic         idu_fetch_entry_valid_o,
    input  logic         idu_fetch_entry_ready_i,

    input logic flush_i
);

  // payload无需复位；entry_present_q为0时，entry_q中的旧值没有接口语义。
  fetch_entry_t entry_q;
  logic         entry_present_q;

  logic ifu_fetch_entry_handshake_occurred;
  logic idu_fetch_entry_handshake_occurred;

  // 空buffer使用fast bypass；buffer已占用时仍由寄存器稳定输出。ready在空buffer时恒为1，
  // 因为即使IDU本拍不接收，也可以在上升沿把IFU entry保存到唯一槽位。flush不组合门控
  // IDU valid，否则当前正在产生redirect的指令会压低自己的valid并形成组合环；更年轻的
  // I-cache响应由IFU的epoch/source-PC检查负责丢弃。
  always_comb begin
    idu_fetch_entry_o       = entry_present_q ? entry_q : ifu_fetch_entry_i;
    idu_fetch_entry_valid_o = entry_present_q || ifu_fetch_entry_valid_i;
    ifu_fetch_entry_ready_o = !entry_present_q || idu_fetch_entry_ready_i;

    ifu_fetch_entry_handshake_occurred = ifu_fetch_entry_valid_i &&
                                         ifu_fetch_entry_ready_o;
    idu_fetch_entry_handshake_occurred = idu_fetch_entry_valid_o &&
                                         idu_fetch_entry_ready_i;
  end

  // flush优先级最高。其余情况下根据两个握手更新槽位：
  // - 仅IFU握手：IDU未接收旁路数据，把entry保存并置present；
  // - 仅IDU握手：已有entry被消费，清present；
  // - 两侧同时握手且原来已满：旧entry出队，新entry原位替换；
  // - 两侧同时握手且原来为空：数据完成纯旁路，不占用槽位。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      entry_present_q <= 1'b0;
    end else if (flush_i) begin
      entry_present_q <= 1'b0;
    end else if (ifu_fetch_entry_handshake_occurred &&
                 !idu_fetch_entry_handshake_occurred) begin
      entry_present_q <= 1'b1;
    end else if (!ifu_fetch_entry_handshake_occurred &&
                 idu_fetch_entry_handshake_occurred) begin
      entry_present_q <= 1'b0;
    end else if (ifu_fetch_entry_handshake_occurred &&
                 idu_fetch_entry_handshake_occurred) begin
      entry_present_q <= entry_present_q;
    end
  end

  always_ff @(posedge clk_i) begin
    if (ifu_fetch_entry_handshake_occurred &&
        (entry_present_q || !idu_fetch_entry_handshake_occurred)) begin
      entry_q <= ifu_fetch_entry_i;
    end
  end

`ifndef SYNTHESIS
  a_output_stable_while_idu_waits :
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (idu_fetch_entry_valid_o && !idu_fetch_entry_ready_i && !flush_i)
    |=> (flush_i || (idu_fetch_entry_valid_o && $stable(idu_fetch_entry_o))))
    else $error("fetch buffer output changed while IDU applied backpressure");

  a_flush_clears_entry :
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    flush_i |=> !entry_present_q)
    else $error("fetch buffer entry remained present after flush");

  a_full_buffer_accepts_only_when_current_entry_leaves :
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (entry_present_q && !idu_fetch_entry_ready_i) |-> !ifu_fetch_entry_ready_o)
    else $error("fetch buffer accepted a second entry while its only slot was occupied");

  a_empty_buffer_bypasses_without_allocating :
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (!entry_present_q && ifu_fetch_entry_valid_i && idu_fetch_entry_ready_i && !flush_i)
    |=> !entry_present_q)
    else $error("fetch buffer allocated storage for an entry consumed through fast bypass");
`endif

endmodule
