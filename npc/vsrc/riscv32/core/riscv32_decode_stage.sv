// 译码流水级队列。IDU只负责把指令编码转换为语义uop，本模块在IDU之后建立
// 明确的时序边界，使寄存器堆/CSR读取和冒险判断不再与完整指令译码位于同一条路径。
//
// 两项弹性缓冲使用固定主项和单项skid，而不是环形队列。输出永远来自主项，因此
// uop中的rs1/rs2地址不会先经过动态head选择mux再驱动寄存器堆读口。上游ready只由
// skid有效位产生，不依赖下游ready；稳态下仍可每拍同时接收和送出一条uop。
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
  decoded_uop_t skid_decoded_uop_q;
  logic         decoded_uop_valid_q;
  logic         skid_decoded_uop_valid_q;
  logic         input_handshake_occurred;
  logic         output_handshake_occurred;

  assign idu_decoded_uop_ready_o   = !skid_decoded_uop_valid_q && !flush_i;
  assign decoded_uop_o             = decoded_uop_q;
  assign decoded_uop_valid_o       = decoded_uop_valid_q;
  assign input_handshake_occurred  = idu_decoded_uop_valid_i && idu_decoded_uop_ready_o;
  assign output_handshake_occurred = decoded_uop_valid_q && decoded_uop_ready_i;

  // payload不承载有效性，因此无需复位或flush。输出被消费时，skid项优先前移；
  // 如果没有skid而上下游同拍握手，新uop可直接替换刚被消费的主项。
  always_ff @(posedge clk_i) begin
    if (output_handshake_occurred) begin
      if (skid_decoded_uop_valid_q) begin
        decoded_uop_q <= skid_decoded_uop_q;
      end else if (input_handshake_occurred) begin
        decoded_uop_q <= idu_decoded_uop_i;
      end
    end else if (input_handshake_occurred) begin
      if (!decoded_uop_valid_q) begin
        decoded_uop_q <= idu_decoded_uop_i;
      end else begin
        skid_decoded_uop_q <= idu_decoded_uop_i;
      end
    end
  end

  // flush只清有效位；错误路径payload可以物理保留，但不会再被下游解释为有效uop。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      decoded_uop_valid_q      <= 1'b0;
      skid_decoded_uop_valid_q <= 1'b0;
    end else if (flush_i) begin
      decoded_uop_valid_q      <= 1'b0;
      skid_decoded_uop_valid_q <= 1'b0;
    end else if (output_handshake_occurred) begin
      if (skid_decoded_uop_valid_q) begin
        decoded_uop_valid_q      <= 1'b1;
        skid_decoded_uop_valid_q <= 1'b0;
      end else if (input_handshake_occurred) begin
        decoded_uop_valid_q <= 1'b1;
      end else begin
        decoded_uop_valid_q <= 1'b0;
      end
    end else if (input_handshake_occurred) begin
      if (!decoded_uop_valid_q) begin
        decoded_uop_valid_q <= 1'b1;
      end else begin
        skid_decoded_uop_valid_q <= 1'b1;
      end
    end
  end

`ifndef SYNTHESIS
  /* verilator lint_off SYNCASYNCNET */
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (decoded_uop_valid_o && !decoded_uop_ready_i && !flush_i)
    |=> (decoded_uop_valid_o && $stable(decoded_uop_o)))
  else $error("decode queue changed uop while backpressured");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    skid_decoded_uop_valid_q |-> decoded_uop_valid_q)
  else $error("decode skid entry became valid without a primary entry");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    flush_i |=> !decoded_uop_valid_o)
  else $error("decode queue retained a flushed uop");
  /* verilator lint_on SYNCASYNCNET */
`endif

endmodule
