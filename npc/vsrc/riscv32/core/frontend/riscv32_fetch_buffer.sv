// IFU响应与IDU消费之间的小型弹性队列。
//
// 本模块只保存已经完成的fetch entry并吸收短暂的译码反压，不参与PC选择、cache命中、
// 分支恢复或指令译码。队列采用寄存式输出，不提供空队列组合穿透：这样可以切断
// I-cache响应到IDU冒险判断再返回前端ready的长组合路径，同时仍能在稳态每拍入队和出队。
module riscv32_fetch_buffer
  import riscv32_pkg::*;
#(
    parameter int unsigned ENTRY_COUNT = 2
) (
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

  localparam int unsigned ENTRY_INDEX_WIDTH = (ENTRY_COUNT > 1) ? $clog2(ENTRY_COUNT) : 1;
  localparam int unsigned ENTRY_COUNT_WIDTH = $clog2(ENTRY_COUNT + 1);
  typedef logic [ENTRY_INDEX_WIDTH-1:0] entry_index_t;
  typedef logic [ENTRY_COUNT_WIDTH-1:0] entry_count_t;

  fetch_entry_t entry_array_q[ENTRY_COUNT];
  entry_index_t read_entry_index_q, read_entry_index_d;
  entry_index_t write_entry_index_q, write_entry_index_d;
  entry_count_t entry_count_q, entry_count_d;

  logic queue_empty;
  logic queue_full;
  logic ifu_fetch_entry_handshake_occurred;
  logic idu_fetch_entry_handshake_occurred;

  function automatic entry_index_t get_next_entry_index(input entry_index_t current_index);
    if (current_index == entry_index_t'(ENTRY_COUNT - 1)) begin
      return '0;
    end
    return current_index + entry_index_t'(1);
  endfunction

  initial begin
    if (ENTRY_COUNT < 1) begin
      $fatal(1, "fetch buffer ENTRY_COUNT must be at least 1");
    end
  end

  assign queue_empty = entry_count_q == entry_count_t'(0);
  assign queue_full  = entry_count_q == entry_count_t'(ENTRY_COUNT);

  // 入口ready只依赖寄存的队列占用量，不依赖本拍IDU是否出队。这样EX级冒险判断不会经
  // IDU ready、队列出队条件和IFU response握手一路反馈到下一取指PC。两项队列在解除长
  // 阻塞后仍可连续向IDU提供已有entry；被释放的槽位从下一拍开始接收新的IFU响应。
  // flush不能组合压低当前输出valid，但必须压低入口ready：ready/valid一旦同时为1就表示
  // sink已经接收该entry，不能在时钟沿悄悄丢弃。core只把寄存后的redirect接到这里，
  // 因而flush不会把EX/commit组合路径重新接入前端ready。
  always_comb begin
    idu_fetch_entry_o       = entry_array_q[read_entry_index_q];
    idu_fetch_entry_valid_o = !queue_empty;
    ifu_fetch_entry_ready_o = !queue_full && !flush_i;

    ifu_fetch_entry_handshake_occurred = ifu_fetch_entry_valid_i && ifu_fetch_entry_ready_o;
    idu_fetch_entry_handshake_occurred = idu_fetch_entry_valid_o && idu_fetch_entry_ready_i;
  end

  always_comb begin
    read_entry_index_d  = read_entry_index_q;
    write_entry_index_d = write_entry_index_q;
    entry_count_d       = entry_count_q;

    if (ifu_fetch_entry_handshake_occurred) begin
      write_entry_index_d = get_next_entry_index(write_entry_index_q);
    end
    if (idu_fetch_entry_handshake_occurred) begin
      read_entry_index_d = get_next_entry_index(read_entry_index_q);
    end

    unique case ({ifu_fetch_entry_handshake_occurred, idu_fetch_entry_handshake_occurred})
      2'b10:   entry_count_d = entry_count_q + entry_count_t'(1);
      2'b01:   entry_count_d = entry_count_q - entry_count_t'(1);
      default: ;
    endcase

    if (flush_i) begin
      read_entry_index_d  = '0;
      write_entry_index_d = '0;
      entry_count_d       = '0;
    end
  end

  // 控制状态需要复位；payload只在真实入队时写入，有效性完全由entry_count_q管理。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      read_entry_index_q  <= '0;
      write_entry_index_q <= '0;
      entry_count_q       <= '0;
    end else begin
      read_entry_index_q  <= read_entry_index_d;
      write_entry_index_q <= write_entry_index_d;
      entry_count_q       <= entry_count_d;
    end
  end

  always_ff @(posedge clk_i) begin
    if (ifu_fetch_entry_handshake_occurred) begin
      entry_array_q[write_entry_index_q] <= ifu_fetch_entry_i;
    end
  end

`ifndef SYNTHESIS
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    entry_count_q <= entry_count_t'(ENTRY_COUNT))
  else $error("fetch buffer entry count exceeded capacity");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    queue_empty |-> !idu_fetch_entry_handshake_occurred)
  else $error("fetch buffer dequeued while empty");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    queue_full |-> !ifu_fetch_entry_handshake_occurred)
  else $error("fetch buffer accepted an entry while full");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (idu_fetch_entry_valid_o && !idu_fetch_entry_ready_i && !flush_i)
    |=> (flush_i || (idu_fetch_entry_valid_o && $stable(idu_fetch_entry_o))))
  else $error("fetch buffer output changed while IDU applied backpressure");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    flush_i |=> (entry_count_q == entry_count_t'(0)))
  else $error("fetch buffer was not empty after flush");
`endif

endmodule
