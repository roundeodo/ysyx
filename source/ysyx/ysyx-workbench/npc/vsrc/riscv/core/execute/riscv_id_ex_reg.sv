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
    input  logic               [1:0] operand_pending_vector_i,
    input  scoreboard_index_t        operand_producer_index_array_i   [2],
    input  completion_source_e       operand_completion_source_array_i[2],
    input  arithmetic_result_t       completion_result_array_i        [3],
    input  logic               [2:0] completion_valid_vector_i,
    output logic                     operands_ready_o,
    // 乘除输入不直接串接 D-cache 读数据路径；load 返回先保存到现有操作数槽。
    output xlen_data_t               muldiv_operand_array_o           [2],

    // 保留给旧冒险控制测试的生产者类别标记，与指令有效位同沿更新。
    // forwardable 表示 ALU/分支类别，不代表等待中的源已经就绪；仍需 operands_ready。
    output logic execute_forwardable_producer_present_o,
    output logic execute_blocking_producer_present_o,
    output logic execute_serializing_instruction_present_o,

    // flush 在时钟沿清除有效位，不组合屏蔽 ready。
    // 恢复拍的执行副作用由 Issue 控制器的 execute_issue_allowed 单独禁止。
    input logic flush_i
);

  // 单项弹性寄存器：空闲或旧指令交付时采样；反压保持；flush 只清有效性。
  execute_packet_t execute_packet_q;
  logic execute_packet_valid_q;
  logic forwardable_producer_present_q;
  logic blocking_producer_present_q;
  logic serializing_instruction_present_q;
  logic decoded_writer_present;
  logic decoded_result_forwardable;

  logic [1:0] operand_pending_vector_q;
  scoreboard_index_t operand_producer_index_array_q[2];
  completion_source_e operand_completion_source_array_q[2];
  logic [1:0] operand_returned_vector;
  logic [1:0] operand_bypass_allowed_vector;
  xlen_data_t operand_return_value_array[2];

  assign decoded_execute_packet_ready_o = !execute_packet_valid_q || execute_packet_ready_i;

  // 完成端口选择 → 生产者索引匹配 → 操作数前递与就绪判断。
  // ALU 等可直接使用 load 返回；乘除输入仍先保存 load 值。
  always_comb begin
    operand_returned_vector       = '0;
    operand_bypass_allowed_vector = '0;
    muldiv_operand_array_o[0]     = execute_packet_q.source_a_value;
    muldiv_operand_array_o[1]     = execute_packet_q.source_b_value;
    operand_return_value_array[0] = '0;
    operand_return_value_array[1] = '0;
    for (int source_index = 0; source_index < 2; source_index++) begin
      operand_bypass_allowed_vector[source_index] =
          operand_completion_source_array_q[source_index] != COMPLETION_LSU ||
          execute_packet_q.uop.fu_type != FU_MULDIV;
      if (operand_pending_vector_q[source_index] && operand_completion_source_array_q[source_index] != COMPLETION_LSU)
        muldiv_operand_array_o[source_index] =
            operand_completion_source_array_q[source_index] == COMPLETION_MULTIPLY ?
            completion_result_array_i[COMPLETION_MULTIPLY].result : completion_result_array_i[COMPLETION_DIVIDE].result;
      // 数据端口已由生产者类型选定，不用迟到的 valid/异常信号选择 64 位数据。
      operand_return_value_array[source_index] = completion_result_array_i[operand_completion_source_array_q[source_index]].result;
      operand_returned_vector[source_index]    = operand_pending_vector_q[source_index] &&
          completion_valid_vector_i[operand_completion_source_array_q[source_index]] &&
          operand_producer_index_array_q[source_index] ==
          completion_result_array_i[operand_completion_source_array_q[source_index]].scoreboard_index;
    end
    execute_packet_o = execute_packet_q;
    if (operand_pending_vector_q[0])
      execute_packet_o.source_a_value = operand_return_value_array[0];
    if (operand_pending_vector_q[1])
      execute_packet_o.source_b_value = operand_return_value_array[1];
  end
  assign operands_ready_o = !(|(operand_pending_vector_q & ~(operand_returned_vector & operand_bypass_allowed_vector)));

  assign execute_packet_valid_o = execute_packet_valid_q;
  assign execute_forwardable_producer_present_o = forwardable_producer_present_q;
  assign execute_blocking_producer_present_o = blocking_producer_present_q;
  assign execute_serializing_instruction_present_o = serializing_instruction_present_q;
  assign decoded_writer_present = decoded_execute_packet_valid_i &&
      decoded_execute_packet_i.uop.writes_rd && decoded_execute_packet_i.uop.rd != '0;
  assign decoded_result_forwardable = decoded_writer_present &&
      !decoded_execute_packet_i.uop.exception_valid &&
      ((decoded_execute_packet_i.uop.fu_type == FU_INT) ||
       (decoded_execute_packet_i.uop.fu_type == FU_BRANCH));

  // 等待位在返回时清除；指令载荷、生产者身份和返回数值由下面的数据寄存器保存。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) operand_pending_vector_q <= '0;
    else if (flush_i) operand_pending_vector_q <= '0;
    else if (decoded_execute_packet_ready_o)
      operand_pending_vector_q <= decoded_execute_packet_valid_i ? operand_pending_vector_i : '0;
    else operand_pending_vector_q <= operand_pending_vector_q & ~operand_returned_vector;
  end

  always_ff @(posedge clk_i) begin
    if (decoded_execute_packet_ready_o) begin
      execute_packet_q                  <= decoded_execute_packet_i;
      operand_producer_index_array_q    <= operand_producer_index_array_i;
      operand_completion_source_array_q <= operand_completion_source_array_i;
    end else begin
      if (operand_returned_vector[0])
        execute_packet_q.source_a_value <= operand_return_value_array[0];
      if (operand_returned_vector[1])
        execute_packet_q.source_b_value <= operand_return_value_array[1];
    end
  end

  // 窄分类与 payload 同沿更新，供旧冒险控制测试直接使用；当前 core 不连接这三个输出。
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
      forwardable_producer_present_q    <= decoded_result_forwardable;
      blocking_producer_present_q       <= decoded_writer_present && !decoded_result_forwardable;
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
