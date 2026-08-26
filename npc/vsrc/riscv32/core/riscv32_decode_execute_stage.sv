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

  execute_packet_t execute_packet_q;
  logic            execute_packet_valid_q;
  logic            execute_packet_valid_d;
  logic            stage_can_accept;

  assign stage_can_accept = !execute_packet_valid_q || execute_packet_ready_i;

  // flush期间不向IDU返回ready，避免上游把一条实际未保存的指令误认为已经交付。
  assign decoded_execute_packet_ready_o = stage_can_accept && !flush_i;
  assign execute_packet_o               = execute_packet_q;
  assign execute_packet_valid_o         = execute_packet_valid_q;

  always_comb begin
    execute_packet_valid_d = execute_packet_valid_q;

    if (stage_can_accept) begin
      execute_packet_valid_d = decoded_execute_packet_valid_i;
    end

    // 恢复优先级高于正常流动：错误路径payload不得在flush边沿后继续有效。
    if (flush_i) begin
      execute_packet_valid_d = 1'b0;
    end
  end

  // payload本身无需复位；valid=0时其数值没有语义，可避免宽payload异步复位网络。
  always_ff @(posedge clk_i) begin
    if (decoded_execute_packet_valid_i && decoded_execute_packet_ready_o) begin
      execute_packet_q <= decoded_execute_packet_i;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      execute_packet_valid_q <= 1'b0;
    end else begin
      execute_packet_valid_q <= execute_packet_valid_d;
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
  /* verilator lint_on SYNCASYNCNET */
`endif

endmodule
