// 译码流水级队列。IDU只负责把指令编码转换为语义uop，本模块在IDU之后建立
// 明确的时序边界，使寄存器堆/CSR读取和冒险判断不再与完整指令译码位于同一条路径。
//
// 两项队列的上游ready只由已寄存的entry_count_q产生，不依赖下游ready。这样既能在
// 稳态下每拍同时接收和送出一条uop，又不会形成WB/LSU/冒险逻辑反向穿越到IDU的长路径。
module riscv32_decode_stage
  import riscv32_pkg::*;
(
    input logic clk_i,
    input logic rst_ni,

    input  decoded_uop_t idu_decoded_uop_i,
    input  logic         idu_decoded_uop_valid_i,
    output logic         idu_decoded_uop_ready_o,

    output decoded_uop_t decoded_uop_o,
    output logic         decoded_uop_valid_o,
    input  logic         decoded_uop_ready_i,

    input logic flush_i
);

  localparam int unsigned ENTRY_COUNT = 2;

  decoded_uop_t decoded_uop_array_q[ENTRY_COUNT];
  logic         read_entry_index_q;
  logic         read_entry_index_d;
  logic         write_entry_index_q;
  logic         write_entry_index_d;
  logic [1:0]   entry_count_q;
  logic [1:0]   entry_count_d;
  logic         input_handshake_occurred;
  logic         output_handshake_occurred;

  assign idu_decoded_uop_ready_o   = (entry_count_q != ENTRY_COUNT) && !flush_i;
  assign decoded_uop_valid_o       = (entry_count_q != 0);
  assign decoded_uop_o             = decoded_uop_array_q[read_entry_index_q];
  assign input_handshake_occurred  = idu_decoded_uop_valid_i && idu_decoded_uop_ready_o;
  assign output_handshake_occurred = decoded_uop_valid_o && decoded_uop_ready_i;

  always_comb begin
    read_entry_index_d  = read_entry_index_q;
    write_entry_index_d = write_entry_index_q;
    entry_count_d       = entry_count_q;

    if (input_handshake_occurred) begin
      write_entry_index_d = write_entry_index_q + 1'b1;
    end

    if (output_handshake_occurred) begin
      read_entry_index_d = read_entry_index_q + 1'b1;
    end

    unique case ({input_handshake_occurred, output_handshake_occurred})
      2'b10: entry_count_d = entry_count_q + 1'b1;
      2'b01: entry_count_d = entry_count_q - 1'b1;
      default: ;
    endcase

    // 恢复事件优先于正常握手；ready在flush周期为0，因此不会接收错误路径uop。
    if (flush_i) begin
      read_entry_index_d  = '0;
      write_entry_index_d = '0;
      entry_count_d       = '0;
    end
  end

  // payload在对应输入握手时写入。写索引和占用数均来自寄存状态，因此该写使能
  // 不包含后端ready链，也不会重新引入跨越整条流水线的组合路径。
  always_ff @(posedge clk_i) begin
    if (input_handshake_occurred) begin
      decoded_uop_array_q[write_entry_index_q] <= idu_decoded_uop_i;
    end
  end

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

`ifndef SYNTHESIS
  /* verilator lint_off SYNCASYNCNET */
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (decoded_uop_valid_o && !decoded_uop_ready_i && !flush_i)
    |=> (decoded_uop_valid_o && $stable(decoded_uop_o)))
  else $error("decode queue changed uop while backpressured");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    entry_count_q <= ENTRY_COUNT)
  else $error("decode queue occupancy exceeded its capacity");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    flush_i |=> !decoded_uop_valid_o)
  else $error("decode queue retained a flushed uop");
  /* verilator lint_on SYNCASYNCNET */
`endif

endmodule
