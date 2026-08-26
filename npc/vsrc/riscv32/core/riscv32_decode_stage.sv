// 译码流水级寄存器。IDU只负责把指令编码转换为语义uop，本模块在IDU之后建立
// 明确的时序边界，使寄存器堆/CSR读取和冒险判断不再与完整指令译码位于同一条路径。
// 该级采用单项弹性寄存器：下游同拍消费时可同时接收下一条uop，稳态吞吐仍为1条/拍。
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

  decoded_uop_t decoded_uop_q;
  logic         decoded_uop_valid_q;
  logic         decoded_uop_valid_d;
  logic         stage_can_accept;

  assign stage_can_accept        = !decoded_uop_valid_q || decoded_uop_ready_i;
  assign idu_decoded_uop_ready_o = stage_can_accept && !flush_i;
  assign decoded_uop_o           = decoded_uop_q;
  assign decoded_uop_valid_o     = decoded_uop_valid_q;

  always_comb begin
    decoded_uop_valid_d = decoded_uop_valid_q;

    if (stage_can_accept) begin
      decoded_uop_valid_d = idu_decoded_uop_valid_i;
    end

    // 恢复事件优先于正常接收，避免上升沿同时把错误路径uop写成有效。
    if (flush_i) begin
      decoded_uop_valid_d = 1'b0;
    end
  end

  // payload在valid=0时没有语义，因此不接复位网络；只在真实握手时改写。
  always_ff @(posedge clk_i) begin
    if (idu_decoded_uop_valid_i && idu_decoded_uop_ready_o) begin
      decoded_uop_q <= idu_decoded_uop_i;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      decoded_uop_valid_q <= 1'b0;
    end else begin
      decoded_uop_valid_q <= decoded_uop_valid_d;
    end
  end

`ifndef SYNTHESIS
  /* verilator lint_off SYNCASYNCNET */
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (decoded_uop_valid_o && !decoded_uop_ready_i && !flush_i)
    |=> (decoded_uop_valid_o && $stable(decoded_uop_o)))
  else $error("decode stage changed uop while backpressured");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    flush_i |=> !decoded_uop_valid_o)
  else $error("decode stage retained a flushed uop");
  /* verilator lint_on SYNCASYNCNET */
`endif

endmodule
