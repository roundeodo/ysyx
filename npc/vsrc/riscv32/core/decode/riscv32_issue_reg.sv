// Decode/Issue 边界：只保存译码后的指令，操作数在 Issue 级读取和前递。
module riscv32_issue_reg
  import riscv32_pkg::*;
(
    input  logic         clk_i,
    input  logic         rst_ni,
    input  decoded_uop_t decoded_uop_i,
    input  logic         decoded_uop_valid_i,
    output logic         decoded_uop_ready_o,
    output decoded_uop_t issue_uop_o,
    output logic         issue_uop_valid_o,
    input  logic         issue_uop_ready_i,
    input  logic         flush_i
);
  decoded_uop_t issue_uop_q;
  logic issue_uop_valid_q;
  logic decode_handshake;

  // 没有空时直通。旧项发射与新项接收可同拍，持续供给时吞吐一条/拍。
  assign issue_uop_o         = issue_uop_q;
  assign issue_uop_valid_o   = issue_uop_valid_q && !flush_i;
  assign decoded_uop_ready_o = !flush_i && (!issue_uop_valid_q || issue_uop_ready_i);
  assign decode_handshake    = decoded_uop_valid_i && decoded_uop_ready_o;

  // 载荷只在接收新指令时写入；阻塞保持，恢复只需清有效位。
  always_ff @(posedge clk_i) begin
    if (decode_handshake) issue_uop_q <= decoded_uop_i;
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) issue_uop_valid_q <= 1'b0;
    else if (flush_i) issue_uop_valid_q <= 1'b0;
    else if (decoded_uop_ready_o) issue_uop_valid_q <= decoded_uop_valid_i;
  end

`ifndef SYNTHESIS
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    issue_uop_valid_o && !issue_uop_ready_i |=>
      flush_i || (issue_uop_valid_o && $stable(
      issue_uop_o
  )))
  else $error("Issue instruction changed while blocked");
  assert property (@(posedge clk_i) disable iff (!rst_ni) flush_i |=> !issue_uop_valid_q)
  else $error("Issue retained a flushed instruction");
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    flush_i |-> !decoded_uop_ready_o && !issue_uop_valid_o)
  else $error("Issue accepted or issued an instruction during recovery");
`endif
endmodule
