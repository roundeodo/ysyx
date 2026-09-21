// ID/EX流水级寄存器。它只保存已经完成译码和寄存器读取的执行payload，
// 不负责译码、冒险判断或执行；这些职责分别属于IDU、hazard controller和EXU。
module riscv32_id_ex_reg
  import riscv32_pkg::*;
(
    input  logic clk_i,
    input  logic rst_ni,

    input  execute_packet_t decoded_execute_packet_i,
    input  logic            decoded_execute_packet_valid_i,
    output logic            decoded_execute_packet_ready_o,

    output execute_packet_t execute_packet_o,
    output logic            execute_packet_valid_o,
    input  logic            execute_packet_ready_i,

    // 冒险控制只需要下面三个窄状态，不应从execute_packet_valid和宽uop重新组合译码。
    // 它们与主槽payload在同一时钟沿更新，分别表示当前EX指令产生的结果能否立即前递、
    // 是否必须等待后级结果，以及当前指令是否要求流水线串行化。
    output logic execute_forwardable_producer_present_o,
    output logic execute_blocking_producer_present_o,
    output logic execute_serializing_instruction_present_o,

    // flush 在时钟沿清除有效位，不组合屏蔽 ready。
    // 恢复拍的执行副作用由 hazard controller 的 issue_allowed 单独禁止。
    input  logic flush_i
);

  // 单项弹性寄存器：空闲或旧指令交付时采样；反压保持；flush 只清有效性。
  execute_packet_t execute_packet_q;
  logic execute_packet_valid_q;
  logic forwardable_producer_present_q;
  logic blocking_producer_present_q;
  logic serializing_instruction_present_q;
  logic input_producer_present;
  logic input_forwardable;

  assign decoded_execute_packet_ready_o = !execute_packet_valid_q || execute_packet_ready_i;
  assign execute_packet_o = execute_packet_q;
  assign execute_packet_valid_o = execute_packet_valid_q;
  assign execute_forwardable_producer_present_o = forwardable_producer_present_q;
  assign execute_blocking_producer_present_o = blocking_producer_present_q;
  assign execute_serializing_instruction_present_o = serializing_instruction_present_q;
  assign input_producer_present = decoded_execute_packet_valid_i &&
      decoded_execute_packet_i.uop.writes_rd && decoded_execute_packet_i.uop.rd != '0;
  assign input_forwardable = input_producer_present &&
      !decoded_execute_packet_i.uop.exception_valid &&
      ((decoded_execute_packet_i.uop.fu_type == FU_INT) ||
       (decoded_execute_packet_i.uop.fu_type == FU_BRANCH));

  always_ff @(posedge clk_i) begin
    if (decoded_execute_packet_ready_o)
      execute_packet_q <= decoded_execute_packet_i;
  end

  // 窄分类与 payload 同沿更新，供 hazard 直接使用。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      execute_packet_valid_q <= 1'b0;
      forwardable_producer_present_q <= 1'b0;
      blocking_producer_present_q <= 1'b0;
      serializing_instruction_present_q <= 1'b0;
    end else if (flush_i) begin
      execute_packet_valid_q <= 1'b0;
      forwardable_producer_present_q <= 1'b0;
      blocking_producer_present_q <= 1'b0;
      serializing_instruction_present_q <= 1'b0;
    end else if (decoded_execute_packet_ready_o) begin
      execute_packet_valid_q <= decoded_execute_packet_valid_i;
      forwardable_producer_present_q <= input_forwardable;
      blocking_producer_present_q <= input_producer_present && !input_forwardable;
      serializing_instruction_present_q <= decoded_execute_packet_valid_i &&
          decoded_execute_packet_i.uop.serializing;
    end
  end

`ifndef SYNTHESIS
  /* verilator lint_off SYNCASYNCNET */
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (execute_packet_valid_o && !execute_packet_ready_i && !flush_i)
    |=> (execute_packet_valid_o && $stable(execute_packet_o)))
  else
    $error("ID/EX stage changed payload while backpressured");

  assert property (@(posedge clk_i) disable iff (!rst_ni) flush_i |=> !execute_packet_valid_o)
  else
    $error("ID/EX stage retained a flushed instruction");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    $onehot0({execute_forwardable_producer_present_o,
              execute_blocking_producer_present_o}))
  else
    $error("ID/EX marked one producer as both forwardable and blocking");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (execute_forwardable_producer_present_o || execute_blocking_producer_present_o ||
     execute_serializing_instruction_present_o) |-> execute_packet_valid_o)
  else
    $error("ID/EX timing metadata remained present without a valid execute packet");
  /* verilator lint_on SYNCASYNCNET */
`endif

endmodule
