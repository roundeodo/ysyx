// IFU响应与IDU消费之间的小型弹性队列。
//
// 两项环形队列：空闲时直接交付，反压时保存；满队列允许出队与入队同拍进行。
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

  fetch_entry_t entry_array_q[2];
  logic read_index_q, read_index_d;
  logic write_index_q, write_index_d;
  logic [1:0] entry_count_q, entry_count_d;
  logic ifu_fetch_entry_handshake;
  logic idu_fetch_entry_handshake;

  logic direct_transfer;
  logic stored_push;
  logic stored_pop;

  assign idu_fetch_entry_o = (entry_count_q == 0) ?
      ifu_fetch_entry_i : entry_array_q[read_index_q];
  assign idu_fetch_entry_valid_o = (entry_count_q != 0) ||
      (ifu_fetch_entry_valid_i && !flush_i);
  assign ifu_fetch_entry_ready_o = !flush_i &&
      ((entry_count_q != 2) || idu_fetch_entry_ready_i);
  assign ifu_fetch_entry_handshake = ifu_fetch_entry_valid_i && ifu_fetch_entry_ready_o;
  assign idu_fetch_entry_handshake = idu_fetch_entry_valid_o && idu_fetch_entry_ready_i;
  assign direct_transfer = (entry_count_q == 0) && ifu_fetch_entry_handshake &&
      idu_fetch_entry_handshake;
  assign stored_push = ifu_fetch_entry_handshake && !direct_transfer;
  assign stored_pop = idu_fetch_entry_handshake && (entry_count_q != 0);

  // 控制下一值：只统计落入数组的项；直通不占容量，flush 优先清空。
  always_comb begin
    read_index_d  = read_index_q;
    write_index_d = write_index_q;
    entry_count_d = entry_count_q;
    if (stored_push)
      write_index_d = !write_index_q;
    if (stored_pop)
      read_index_d = !read_index_q;
    unique case ({stored_push, stored_pop})
      2'b10:   entry_count_d = entry_count_q + 2'd1;
      2'b01:   entry_count_d = entry_count_q - 2'd1;
      default: ;
    endcase
    if (flush_i) begin
      read_index_d  = 1'b0;
      write_index_d = 1'b0;
      entry_count_d = 2'd0;
    end
  end

  // 直通交付不写数组；满队列交接在同沿读旧项、写入新项。
  always_ff @(posedge clk_i) begin
    if (stored_push) begin
      entry_array_q[write_index_q] <= ifu_fetch_entry_i;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      read_index_q  <= 1'b0;
      write_index_q <= 1'b0;
      entry_count_q <= 2'd0;
    end else begin
      read_index_q  <= read_index_d;
      write_index_q <= write_index_d;
      entry_count_q <= entry_count_d;
    end
  end

`ifndef SYNTHESIS
  assert property (@(posedge clk_i) disable iff (!rst_ni) entry_count_q <= 2'd2)
  else $error("fetch buffer occupancy exceeded its capacity");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (idu_fetch_entry_valid_o && !idu_fetch_entry_ready_i && !flush_i)
    |=> (flush_i || (idu_fetch_entry_valid_o && $stable(idu_fetch_entry_o))))
  else $error("fetch buffer output changed while IDU applied backpressure");

  assert property (@(posedge clk_i) disable iff (!rst_ni) flush_i |=> (entry_count_q == 2'd0))
  else $error("fetch buffer was not empty after flush");
`endif

endmodule
