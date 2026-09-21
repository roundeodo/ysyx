// 历史流水级实验：当前 riscv32_core 不实例化此模块。
// 译码流水级。IDU只负责把指令编码转换为语义uop，本模块在IDU之后建立明确的
// 时序边界，使寄存器堆读取不再与完整指令译码位于同一条路径。
//
// 前端fetch buffer已经负责吸收短时反压，因此这里使用单项滚动寄存器，不再重复保存
// 一份宽decoded_uop_t作为skid项。当前项被下游接收的同一拍可以写入下一项，稳态吞吐
// 仍为1条/拍；代价只是ready向前传播一个valid判断，而不是增加第二份payload存储。
module riscv32_decode_stage
  import riscv32_pkg::*;
(
    input  logic clk_i,
    input  logic rst_ni,

    input  decoded_uop_t idu_decoded_uop_i,
    input  logic         idu_decoded_uop_valid_i,
    output logic         idu_decoded_uop_ready_o,

    output decoded_uop_t decoded_uop_o,
    output logic         decoded_uop_valid_o,
    input  logic         decoded_uop_ready_i,

    input  logic flush_i
);

  decoded_uop_t decoded_uop_q;
  logic         decoded_uop_valid_q;

  // rolling ready允许“本拍送出旧项并在同一上升沿接收新项”。flush只清valid，不复位
  // payload；错误路径数据即使物理残留，也不会被下游解释成有效指令。
  assign idu_decoded_uop_ready_o = !decoded_uop_valid_q || decoded_uop_ready_i;
  assign decoded_uop_o           = decoded_uop_q;
  assign decoded_uop_valid_o     = decoded_uop_valid_q;

  always_ff @(posedge clk_i) begin
    if (idu_decoded_uop_ready_o) begin
      decoded_uop_q <= idu_decoded_uop_i;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      decoded_uop_valid_q <= 1'b0;
    end else if (flush_i) begin
      decoded_uop_valid_q <= 1'b0;
    end else if (idu_decoded_uop_ready_o) begin
      decoded_uop_valid_q <= idu_decoded_uop_valid_i;
    end
  end

`ifndef SYNTHESIS
  /* verilator lint_off SYNCASYNCNET */
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (decoded_uop_valid_o && !decoded_uop_ready_i && !flush_i)
    |=> (decoded_uop_valid_o && $stable(decoded_uop_o)))
  else
    $error("decode queue changed uop while backpressured");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    flush_i |=> !decoded_uop_valid_o)
  else
    $error("decode queue retained a flushed uop");
  /* verilator lint_on SYNCASYNCNET */
`endif

endmodule
