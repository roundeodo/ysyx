// ID/EX 保存已译码指令、就绪操作数和未就绪源的生产者索引。
// 完成口可唤醒等待源；operands_ready 与发射授权共同保证 EX 只执行完整操作数。
module riscv_id_ex_reg
  import riscv_pkg::*;
(
    input logic clk_i,
    input logic rst_ni,

    input  execute_packet_t decoded_execute_packet_i,
    input  logic            decoded_execute_packet_valid_i,
    output logic            decoded_execute_packet_ready_o,

    output execute_packet_t execute_packet_o,
    output logic            execute_packet_valid_o,
    input  logic            execute_packet_ready_i,

    // 未就绪源的最近生产者；三个完成口分别来自 LSU、MUL、DIV。
    input  logic               [1:0] operand_pending_i,
    input  scoreboard_index_t        operand_index_i     [2],
    input  completion_source_e       operand_source_i    [2],
    input  arithmetic_result_t       completion_i        [3],
    input  logic               [2:0] completion_valid_i,
    output logic                     operands_ready_o,
    // 乘除输入不直接串接 D-cache 读数据路径；load 返回先保存到现有操作数槽。
    output xlen_data_t               arithmetic_operand_o[2],

    // 冒险控制只需要下面三个窄状态，不应从execute_packet_valid和宽uop重新组合译码。
    // 它们与主槽payload在同一时钟沿更新，分别表示当前EX指令产生的结果能否立即前递、
    // 是否必须等待后级结果，以及当前指令是否要求流水线串行化。
    output logic execute_forwardable_producer_present_o,
    output logic execute_blocking_producer_present_o,
    output logic execute_serializing_instruction_present_o,

    // flush 在时钟沿清除有效位，不组合屏蔽 ready。
    // 恢复拍的执行副作用由 hazard controller 的 issue_allowed 单独禁止。
    input logic flush_i
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
  logic [1:0] operand_pending_q;
  scoreboard_index_t operand_index_q[2];
  completion_source_e operand_source_array_q[2];
  logic [1:0] operand_returned;
  logic [1:0] operand_bypass_allowed;
  xlen_data_t returned_value[2];

  // 返回值同时驱动当前 EX 与等待槽保存端，不要求先寄存再执行。
  always_comb begin
    operand_returned        = '0;
    operand_bypass_allowed  = '0;
    arithmetic_operand_o[0] = execute_packet_q.source_a_value;
    arithmetic_operand_o[1] = execute_packet_q.source_b_value;
    returned_value[0]       = '0;
    returned_value[1]       = '0;
    for (int source_index = 0; source_index < 2; source_index++) begin
      operand_bypass_allowed[source_index] =
          operand_source_array_q[source_index] != COMPLETION_LSU ||
          execute_packet_q.uop.fu_type != FU_MULDIV;
      if (operand_pending_q[source_index] && operand_source_array_q[source_index] != COMPLETION_LSU)
        arithmetic_operand_o[source_index] =
            operand_source_array_q[source_index] == COMPLETION_MULTIPLY ?
            completion_i[COMPLETION_MULTIPLY].result : completion_i[COMPLETION_DIVIDE].result;
      // 数据端口已由生产者类型选定，不用迟到的 valid/异常信号选择 64 位数据。
      returned_value[source_index]   = completion_i[operand_source_array_q[source_index]].result;
      operand_returned[source_index] = operand_pending_q[source_index] &&
          completion_valid_i[operand_source_array_q[source_index]] &&
          operand_index_q[source_index] ==
          completion_i[operand_source_array_q[source_index]].scoreboard_index;
    end
    execute_packet_o = execute_packet_q;
    if (operand_pending_q[0]) execute_packet_o.source_a_value = returned_value[0];
    if (operand_pending_q[1]) execute_packet_o.source_b_value = returned_value[1];
  end
  assign operands_ready_o = !(|(operand_pending_q & ~(operand_returned & operand_bypass_allowed)));

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) operand_pending_q <= '0;
    else if (flush_i) operand_pending_q <= '0;
    else if (decoded_execute_packet_ready_o)
      operand_pending_q <= decoded_execute_packet_valid_i ? operand_pending_i : '0;
    else operand_pending_q <= operand_pending_q & ~operand_returned;
  end
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
    if (decoded_execute_packet_ready_o) begin
      execute_packet_q       <= decoded_execute_packet_i;
      operand_index_q        <= operand_index_i;
      operand_source_array_q <= operand_source_i;
    end else begin
      if (operand_returned[0]) execute_packet_q.source_a_value <= returned_value[0];
      if (operand_returned[1]) execute_packet_q.source_b_value <= returned_value[1];
    end
  end

  // 窄分类与 payload 同沿更新，供 hazard 直接使用。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      execute_packet_valid_q            <= 1'b0;
      forwardable_producer_present_q    <= 1'b0;
      blocking_producer_present_q       <= 1'b0;
      serializing_instruction_present_q <= 1'b0;
    end else if (flush_i) begin
      execute_packet_valid_q            <= 1'b0;
      forwardable_producer_present_q    <= 1'b0;
      blocking_producer_present_q       <= 1'b0;
      serializing_instruction_present_q <= 1'b0;
    end else if (decoded_execute_packet_ready_o) begin
      execute_packet_valid_q            <= decoded_execute_packet_valid_i;
      forwardable_producer_present_q    <= input_forwardable;
      blocking_producer_present_q       <= input_producer_present && !input_forwardable;
      serializing_instruction_present_q <= decoded_execute_packet_valid_i &&
          decoded_execute_packet_i.uop.serializing;
    end
  end

`ifndef SYNTHESIS
  /* verilator lint_off SYNCASYNCNET */
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (execute_packet_valid_o && operands_ready_o && !execute_packet_ready_i && !flush_i)
    |=> (execute_packet_valid_o && $stable(
      execute_packet_o
  )))
  else $error("ID/EX stage changed payload while backpressured");

  // 操作数可在等待期间变为就绪，指令身份与 CSR 数据必须保持。
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (execute_packet_valid_o && !execute_packet_ready_i && !flush_i) |=>
      (execute_packet_valid_o && $stable(
      {execute_packet_o.uop, execute_packet_o.csr_rdata, execute_packet_o.csr_illegal}
  )))
  else $error("Waiting instruction changed identity");

  assert property (@(posedge clk_i) disable iff (!rst_ni) flush_i |=> !execute_packet_valid_o)
  else $error("ID/EX stage retained a flushed instruction");

  assert property (@(posedge clk_i) disable iff (!rst_ni) $onehot0(
      {execute_forwardable_producer_present_o, execute_blocking_producer_present_o}
  ))
  else $error("ID/EX marked one producer as both forwardable and blocking");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (execute_forwardable_producer_present_o || execute_blocking_producer_present_o ||
     execute_serializing_instruction_present_o) |-> execute_packet_valid_o)
  else $error("ID/EX timing metadata remained present without a valid execute packet");
  /* verilator lint_on SYNCASYNCNET */
`endif

endmodule
