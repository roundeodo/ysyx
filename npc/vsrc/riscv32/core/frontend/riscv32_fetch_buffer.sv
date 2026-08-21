// IFU响应与IDU消费之间的单项弹性寄存器。
//
// 当前核心同一时刻只允许一条指令进入执行路径，前端也只有一个阻塞式I-cache miss在途，
// 因此第二个fetch entry只会增加寄存器面积，不会增加可持续吞吐。单项实现仍允许同一周期
// 消费旧entry并接收新entry，连续命中且IDU持续ready时可以保持每周期交付一条指令。
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

  // 不提供空buffer组合旁路，避免I-cache响应穿过IDU、EXU和提交路径后再反馈到前端。
  // 已占用但IDU本拍会消费时，ready仍为1；上升沿直接用新entry替换旧entry，不产生空拍。
  always_comb begin
    idu_fetch_entry_o       = entry_q;
    idu_fetch_entry_valid_o = entry_present_q;
    ifu_fetch_entry_ready_o = !flush_i &&
                              (!entry_present_q || idu_fetch_entry_ready_i);

    ifu_fetch_entry_handshake_occurred = ifu_fetch_entry_valid_i &&
                                         ifu_fetch_entry_ready_o;
    idu_fetch_entry_handshake_occurred = idu_fetch_entry_valid_o &&
                                         idu_fetch_entry_ready_i;
  end

  // flush优先级最高。其余情况下，入队优先于单独出队，以实现同拍替换：
  // - enqueue=1：写入新payload并保持present；
  // - enqueue=0、dequeue=1：清present；
  // - 两者均为0：保持当前entry。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      entry_present_q <= 1'b0;
    end else if (flush_i) begin
      entry_present_q <= 1'b0;
    end else if (ifu_fetch_entry_handshake_occurred) begin
      entry_present_q <= 1'b1;
    end else if (idu_fetch_entry_handshake_occurred) begin
      entry_present_q <= 1'b0;
    end
  end

  always_ff @(posedge clk_i) begin
    if (ifu_fetch_entry_handshake_occurred) begin
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
`endif

endmodule
