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

  fetch_entry_t entry_array_q[2];
  logic read_index_q, read_index_d;
  logic write_index_q, write_index_d;
  logic [1:0] entry_count_q, entry_count_d;
  logic ifu_fetch_entry_handshake;
  logic idu_fetch_entry_handshake;

  // 两项环形队列：出队只改变读指针，不把整条备用指令搬回主槽。取消RR后，
  // 译码/冒险产生的ready因此只到达窄指针和数量状态，不再控制宽payload搬移mux。
  // 输出由寄存的读指针选择已有槽位；入口ready只取决于寄存容量，仍无空队列穿透。
  assign idu_fetch_entry_o         = entry_array_q[read_index_q];
  assign idu_fetch_entry_valid_o   = entry_count_q != 2'd0;
  assign ifu_fetch_entry_ready_o   = (entry_count_q != 2'd2) && !flush_i;
  assign ifu_fetch_entry_handshake = ifu_fetch_entry_valid_i && ifu_fetch_entry_ready_o;
  assign idu_fetch_entry_handshake = idu_fetch_entry_valid_o && idu_fetch_entry_ready_i;

  // 控制下一值：同时入队和出队时数量不变，flush 优先清空队列。
  always_comb begin
    read_index_d  = read_index_q;
    write_index_d = write_index_q;
    entry_count_d = entry_count_q;
    if (ifu_fetch_entry_handshake)
      write_index_d = !write_index_q;
    if (idu_fetch_entry_handshake)
      read_index_d = !read_index_q;
    unique case ({ifu_fetch_entry_handshake, idu_fetch_entry_handshake})
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

  // 写入始终只针对空闲槽位，完全不依赖下游本拍是否出队。payload无需复位；
  // flush只清队列状态。旧输出valid保持到时钟沿，由下游自己的flush取消年轻指令。
  always_ff @(posedge clk_i) begin
    if (ifu_fetch_entry_handshake) begin
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
