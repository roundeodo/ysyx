// ID/EX流水级寄存器。它只保存已经完成译码和寄存器读取的执行payload，
// 不负责译码、冒险判断或执行；这些职责分别属于IDU、hazard controller和EXU。
module riscv32_decode_execute_stage
  import riscv32_pkg::*;
(
    input logic clk_i,
    input logic rst_ni,

    input  execute_packet_t decoded_execute_packet_i,
    input  logic            decoded_execute_packet_valid_i,
    output logic            decoded_execute_packet_ready_o,

    output execute_packet_t execute_packet_o,
    output logic            execute_packet_valid_o,
    input  logic            execute_packet_ready_i,

    // flush只删除尚未产生架构副作用的年轻指令。当前输出仍可在本周期被EXU消费，
    // 因而EX级产生redirect的分支自身能够进入WB，下一拍stage中只留下bubble。
    input logic flush_i
);

  // 主寄存器直接驱动EX；skid寄存器只在EX突然反压时保存同拍已经被ID接收的下一条
  // 指令。上游ready只依赖本级skid valid，不再组合穿过EX、LSU、D-cache和WB。
  // 下游连续ready时，主寄存器每拍用新payload替换已消费payload，吞吐仍为1条/拍。
  execute_packet_t execute_packet_q;
  execute_packet_t skid_execute_packet_q;
  logic            execute_packet_valid_q;
  logic            skid_execute_packet_valid_q;
  logic            input_handshake;
  logic            output_handshake;

  assign decoded_execute_packet_ready_o = !skid_execute_packet_valid_q && !flush_i;
  assign execute_packet_o               = execute_packet_q;
  assign execute_packet_valid_o         = execute_packet_valid_q;
  assign input_handshake                 = decoded_execute_packet_valid_i &&
                                           decoded_execute_packet_ready_o;
  assign output_handshake                = execute_packet_valid_q && execute_packet_ready_i;

  // payload本身无需复位；对应valid=0时其数值没有语义。flush只清valid，避免给宽
  // payload布置复位网络。四种流动情况均只在本级寄存器之间选择，不读取下游payload。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      execute_packet_valid_q      <= 1'b0;
      skid_execute_packet_valid_q <= 1'b0;
    end else if (flush_i) begin
      execute_packet_valid_q      <= 1'b0;
      skid_execute_packet_valid_q <= 1'b0;
    end else if (output_handshake) begin
      if (skid_execute_packet_valid_q) begin
        execute_packet_q            <= skid_execute_packet_q;
        execute_packet_valid_q      <= 1'b1;
        skid_execute_packet_valid_q <= 1'b0;
      end else if (input_handshake) begin
        execute_packet_q       <= decoded_execute_packet_i;
        execute_packet_valid_q <= 1'b1;
      end else begin
        execute_packet_valid_q <= 1'b0;
      end
    end else if (input_handshake) begin
      if (!execute_packet_valid_q) begin
        execute_packet_q       <= decoded_execute_packet_i;
        execute_packet_valid_q <= 1'b1;
      end else begin
        skid_execute_packet_q       <= decoded_execute_packet_i;
        skid_execute_packet_valid_q <= 1'b1;
      end
    end
  end

`ifndef SYNTHESIS
  /* verilator lint_off SYNCASYNCNET */
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (execute_packet_valid_o && !execute_packet_ready_i && !flush_i)
    |=> (execute_packet_valid_o && $stable(execute_packet_o)))
  else $error("ID/EX stage changed payload while backpressured");

  assert property (@(posedge clk_i) disable iff (!rst_ni) flush_i |=> !execute_packet_valid_o)
  else $error("ID/EX stage retained a flushed instruction");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    skid_execute_packet_valid_q |-> execute_packet_valid_q)
  else $error("ID/EX skid entry became valid without a primary entry");
  /* verilator lint_on SYNCASYNCNET */
`endif

endmodule
