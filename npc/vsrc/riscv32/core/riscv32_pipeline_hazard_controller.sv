// 顺序流水线的冒险与前递选择模块。该模块只产生允许、阻塞、清空和数据选择决策，
// 不保存payload。比较器集中在这里，避免冒险检测和前递网络分别重复一套寄存器相关判断。
module riscv32_pipeline_hazard_controller
  import riscv32_pkg::*;
(
    input logic clk_i,
    input logic rst_ni,

    input logic          decoded_uop_valid_i,
    input logic          decoded_uses_rs1_i,
    input arch_reg_idx_t decoded_rs1_i,
    input logic          decoded_uses_rs2_i,
    input arch_reg_idx_t decoded_rs2_i,
    input logic          decoded_serializing_i,

    input logic          execute_instruction_present_i,
    input logic          execute_forwardable_producer_present_i,
    input logic          execute_blocking_producer_present_i,
    input arch_reg_idx_t execute_rd_i,
    input logic          execute_serializing_instruction_present_i,

    // EXU结果经过EX/MEM寄存器后再进入完成端。该级中的普通整数结果可前递；但当
    // 下游反压时，年轻指令不能绕过它发起LSU副作用。串行化属性也必须保持到该级离开。
    input logic execute_result_valid_i,
    input logic execute_result_ready_i,
    input logic execute_result_writes_rd_i,
    input arch_reg_idx_t execute_result_rd_i,
    input logic execute_result_forwarding_available_i,
    input logic execute_result_serializing_i,

    input logic          writeback_result_valid_i,
    input logic          writeback_writes_rd_i,
    input arch_reg_idx_t writeback_rd_i,
    input logic          writeback_serializing_i,
    input logic          writeback_forwarding_available_i,

    // 在途LSU事务位于EX与WB之间。目的寄存器必须参与RAW比较；load结果先跨过WB
    // 寄存边界，再通过writeback前递。独立指令允许进入EX等待。
    input logic          lsu_busy_i,
    input logic          lsu_completion_succeeded_i,
    input logic          lsu_pending_writes_rd_i,
    input arch_reg_idx_t lsu_pending_rd_i,
    // 误预测判断来自EX/MEM寄存结果，不经过EXU组合路径。发现误预测的同拍必须阻止
    // 年轻指令产生副作用；frontend_redirect_applied_i在下一拍恢复IFU取指地址。
    input logic execute_redirect_present_i,
    input logic frontend_redirect_applied_i,
    input logic commit_redirect_occurred_i,

    output logic decode_accept_allowed_o,
    output logic execute_progress_allowed_o,
    output logic execute_issue_allowed_o,
    output logic decode_execute_flush_o,
    output logic writeback_flush_o,

    output logic raw_hazard_present_o,
    output logic serializing_hazard_present_o,
    output logic structural_hazard_present_o,

    output logic rs1_execute_forwarding_selected_o,
    output logic rs1_execute_result_forwarding_selected_o,
    output logic rs1_writeback_forwarding_selected_o,
    output logic rs2_execute_forwarding_selected_o,
    output logic rs2_execute_result_forwarding_selected_o,
    output logic rs2_writeback_forwarding_selected_o
);

  logic execute_writes_rs1;
  logic execute_writes_rs2;
  logic execute_forwardable_writes_rs1;
  logic execute_forwardable_writes_rs2;
  logic execute_blocking_writes_rs1;
  logic execute_blocking_writes_rs2;
  logic execute_result_writes_rs1;
  logic execute_result_writes_rs2;
  logic writeback_writes_rs1;
  logic writeback_writes_rs2;
  logic lsu_writes_rs1;
  logic lsu_writes_rs2;
  logic rs1_value_unavailable;
  logic rs2_value_unavailable;
  logic older_serializing_instruction_present;
  logic older_instruction_present;
  logic control_recovery_occurred;
  logic execute_result_stalled;

  always_comb begin
    execute_forwardable_writes_rs1 = decoded_uop_valid_i &&
        execute_forwardable_producer_present_i && decoded_uses_rs1_i &&
        (execute_rd_i == decoded_rs1_i);
    execute_forwardable_writes_rs2 = decoded_uop_valid_i &&
        execute_forwardable_producer_present_i && decoded_uses_rs2_i &&
        (execute_rd_i == decoded_rs2_i);
    execute_blocking_writes_rs1 = decoded_uop_valid_i &&
        execute_blocking_producer_present_i && decoded_uses_rs1_i &&
        (execute_rd_i == decoded_rs1_i);
    execute_blocking_writes_rs2 = decoded_uop_valid_i &&
        execute_blocking_producer_present_i && decoded_uses_rs2_i &&
        (execute_rd_i == decoded_rs2_i);
    execute_writes_rs1 = execute_forwardable_writes_rs1 || execute_blocking_writes_rs1;
    execute_writes_rs2 = execute_forwardable_writes_rs2 || execute_blocking_writes_rs2;

    execute_result_writes_rs1 = decoded_uop_valid_i && execute_result_valid_i &&
                                execute_result_writes_rd_i &&
                                (execute_result_rd_i != '0) && decoded_uses_rs1_i &&
                                (execute_result_rd_i == decoded_rs1_i);
    execute_result_writes_rs2 = decoded_uop_valid_i && execute_result_valid_i &&
                                execute_result_writes_rd_i &&
                                (execute_result_rd_i != '0) && decoded_uses_rs2_i &&
                                (execute_result_rd_i == decoded_rs2_i);

    writeback_writes_rs1 = decoded_uop_valid_i && writeback_result_valid_i &&
                           writeback_writes_rd_i &&
                           (writeback_rd_i != '0) && decoded_uses_rs1_i &&
                           (writeback_rd_i == decoded_rs1_i);
    writeback_writes_rs2 = decoded_uop_valid_i && writeback_result_valid_i &&
                           writeback_writes_rd_i &&
                           (writeback_rd_i != '0) && decoded_uses_rs2_i &&
                           (writeback_rd_i == decoded_rs2_i);

    lsu_writes_rs1 = decoded_uop_valid_i && lsu_busy_i && lsu_pending_writes_rd_i &&
                     (lsu_pending_rd_i != '0) && decoded_uses_rs1_i &&
                     (lsu_pending_rd_i == decoded_rs1_i);
    lsu_writes_rs2 = decoded_uop_valid_i && lsu_busy_i && lsu_pending_writes_rd_i &&
                     (lsu_pending_rd_i != '0) && decoded_uses_rs2_i &&
                     (lsu_pending_rd_i == decoded_rs2_i);

    // 同一架构寄存器可能同时被EX和WB中的两条老指令写入。EX中的生产者年龄更近，
    // 必须优先；如果它的结果尚不可用，不能错误前递WB中的更旧值。
    rs1_execute_forwarding_selected_o = execute_forwardable_writes_rs1;
    rs1_execute_result_forwarding_selected_o = !execute_writes_rs1 &&
        execute_result_writes_rs1 && execute_result_forwarding_available_i;
    rs1_writeback_forwarding_selected_o = !execute_writes_rs1 &&
                                          !execute_result_writes_rs1 &&
                                          !lsu_writes_rs1 &&
                                          writeback_writes_rs1 &&
                                          writeback_forwarding_available_i;
    rs2_execute_forwarding_selected_o = execute_forwardable_writes_rs2;
    rs2_execute_result_forwarding_selected_o = !execute_writes_rs2 &&
        execute_result_writes_rs2 && execute_result_forwarding_available_i;
    rs2_writeback_forwarding_selected_o = !execute_writes_rs2 &&
                                          !execute_result_writes_rs2 &&
                                          !lsu_writes_rs2 &&
                                          writeback_writes_rs2 &&
                                          writeback_forwarding_available_i;

    rs1_value_unavailable = execute_blocking_writes_rs1 ||
                            (!execute_writes_rs1 && execute_result_writes_rs1 &&
                             !execute_result_forwarding_available_i) ||
                            (!execute_writes_rs1 && !execute_result_writes_rs1 &&
                             lsu_writes_rs1) ||
                            (!execute_writes_rs1 && !execute_result_writes_rs1 &&
                             !lsu_writes_rs1 &&
                             writeback_writes_rs1 &&
                             !writeback_forwarding_available_i);
    rs2_value_unavailable = execute_blocking_writes_rs2 ||
                            (!execute_writes_rs2 && execute_result_writes_rs2 &&
                             !execute_result_forwarding_available_i) ||
                            (!execute_writes_rs2 && !execute_result_writes_rs2 &&
                             lsu_writes_rs2) ||
                            (!execute_writes_rs2 && !execute_result_writes_rs2 &&
                             !lsu_writes_rs2 &&
                             writeback_writes_rs2 &&
                             !writeback_forwarding_available_i);
  end

  assign raw_hazard_present_o = decoded_uop_valid_i &&
                                (rs1_value_unavailable || rs2_value_unavailable);

  assign older_instruction_present = execute_instruction_present_i ||
                                     execute_result_valid_i ||
                                     writeback_result_valid_i || lsu_busy_i;
  assign older_serializing_instruction_present =
      execute_serializing_instruction_present_i ||
      (execute_result_valid_i && execute_result_serializing_i) ||
      (writeback_result_valid_i && writeback_serializing_i);

  // 串行化指令必须等所有老指令离开后端后才能进入；进入后又阻止年轻指令，直到自己提交。
  assign serializing_hazard_present_o = decoded_uop_valid_i &&
      (older_serializing_instruction_present ||
       (decoded_serializing_i && older_instruction_present));

  // EX/MEM发现误预测的同拍就清除年轻ID/EX指令并禁止其产生副作用。redirect经过
  // 专用寄存器后，下一拍真正交给前端并再次清除期间可能到达的错误路径指令。
  assign control_recovery_occurred = frontend_redirect_applied_i || commit_redirect_occurred_i;

  // LSU 成功交付 WB 的同拍，年轻普通指令可以进入空的 EX 结果寄存器。
  // 这不提供 load 响应到 ID/EX 的旁路；上面的 pending-rd RAW 检查保持不变。
  assign structural_hazard_present_o = lsu_busy_i && !lsu_completion_succeeded_i;
  assign execute_result_stalled = execute_result_valid_i && !execute_result_ready_i;

  // 恢复事件通过各级flush清valid，不参与decode的ready/accept组合网络。错误路径uop
  // 可以在恢复拍被物理采样，但不会获得valid；因此这里只保留真正需要等待的冒险。
  assign decode_accept_allowed_o = !raw_hazard_present_o &&
                                   !serializing_hazard_present_o;

  // progress只描述后端是否有空间，直接控制ID/EX payload流动；issue再叠加控制恢复，
  // 只控制EXU能否产生completion或访存副作用。这样redirect不会进入宽payload写入路径。
  assign execute_progress_allowed_o = !execute_result_stalled && !structural_hazard_present_o;
  assign execute_issue_allowed_o = execute_progress_allowed_o &&
                                   !execute_redirect_present_i &&
                                   !frontend_redirect_applied_i &&
                                   !commit_redirect_occurred_i;

  assign decode_execute_flush_o = execute_redirect_present_i || control_recovery_occurred;
  assign writeback_flush_o = commit_redirect_occurred_i;

`ifndef SYNTHESIS
  /* verilator lint_off SYNCASYNCNET */
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    raw_hazard_present_o |-> !decode_accept_allowed_o)
  else $error("pipeline accepted a decoded instruction with an unresolved RAW hazard");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    control_recovery_occurred |-> decode_execute_flush_o)
  else $error("pipeline recovery did not flush the ID/EX stage");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    execute_redirect_present_i |-> !execute_issue_allowed_o)
  else $error("pipeline allowed a younger instruction to issue during branch recovery");

  assert property (@(posedge clk_i) disable iff (!rst_ni) (lsu_busy_i && !lsu_completion_succeeded_i) |-> !execute_issue_allowed_o)
  else $error("pipeline issued a younger instruction ahead of an older LSU transaction");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    execute_result_stalled |-> !execute_issue_allowed_o)
  else $error("pipeline issued a younger instruction around a stalled EX/MEM result");

  assert property (@(posedge clk_i) disable iff (!rst_ni) $onehot0(
      {rs1_execute_forwarding_selected_o,
              rs1_execute_result_forwarding_selected_o,
              rs1_writeback_forwarding_selected_o}
  ) && $onehot0(
      {rs2_execute_forwarding_selected_o,
              rs2_execute_result_forwarding_selected_o,
              rs2_writeback_forwarding_selected_o}
  ))
  else $error("pipeline selected multiple forwarding producers for one source operand");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (decoded_uop_valid_i && execute_blocking_writes_rs1)
    |-> raw_hazard_present_o)
  else $error("pipeline accepted stale rs1 data while the newest EX producer was unavailable");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (decoded_uop_valid_i && execute_blocking_writes_rs2)
    |-> raw_hazard_present_o)
  else $error("pipeline accepted stale rs2 data while the newest EX producer was unavailable");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (decoded_uop_valid_i && !execute_writes_rs1 && lsu_writes_rs1)
    |-> raw_hazard_present_o)
  else $error("pipeline accepted stale rs1 data while an LSU producer was pending");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (decoded_uop_valid_i && !execute_writes_rs2 && lsu_writes_rs2)
    |-> raw_hazard_present_o)
  else $error("pipeline accepted stale rs2 data while an LSU producer was pending");
  /* verilator lint_on SYNCASYNCNET */
`endif

endmodule
