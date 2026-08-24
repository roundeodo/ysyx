// 首版顺序流水线的冒险策略模块。该模块只产生允许、阻塞和清空决策，不保存payload。
// 后续加入forwarding时，应在这里缩小RAW阻塞条件，而不是修改IDU或流水级寄存器协议。
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

    input logic          execute_uop_valid_i,
    input logic          execute_writes_rd_i,
    input arch_reg_idx_t execute_rd_i,
    input logic          execute_serializing_i,

    input logic          writeback_result_valid_i,
    input logic          writeback_writes_rd_i,
    input arch_reg_idx_t writeback_rd_i,
    input logic          writeback_serializing_i,

    // 当前LSU是blocking单事务单元。busy期间不允许年轻指令进入ID/EX，既避免
    // completion端口冲突，也避免在未保存LSU目的寄存器的情况下漏检load-use RAW。
    input logic lsu_busy_i,

    input logic execute_redirect_occurred_i,
    input logic commit_redirect_occurred_i,

    output logic decode_accept_allowed_o,
    output logic execute_issue_allowed_o,
    output logic decode_execute_flush_o,
    output logic writeback_flush_o,

    output logic raw_hazard_present_o,
    output logic serializing_hazard_present_o,
    output logic structural_hazard_present_o
);

  logic execute_writes_rs1;
  logic execute_writes_rs2;
  logic writeback_writes_rs1;
  logic writeback_writes_rs2;
  logic older_serializing_instruction_present;
  logic older_instruction_present;
  logic control_recovery_occurred;

  always_comb begin
    execute_writes_rs1 = execute_uop_valid_i && execute_writes_rd_i &&
                         (execute_rd_i != '0) && decoded_uses_rs1_i &&
                         (execute_rd_i == decoded_rs1_i);
    execute_writes_rs2 = execute_uop_valid_i && execute_writes_rd_i &&
                         (execute_rd_i != '0) && decoded_uses_rs2_i &&
                         (execute_rd_i == decoded_rs2_i);

    writeback_writes_rs1 = writeback_result_valid_i && writeback_writes_rd_i &&
                           (writeback_rd_i != '0) && decoded_uses_rs1_i &&
                           (writeback_rd_i == decoded_rs1_i);
    writeback_writes_rs2 = writeback_result_valid_i && writeback_writes_rd_i &&
                           (writeback_rd_i != '0) && decoded_uses_rs2_i &&
                           (writeback_rd_i == decoded_rs2_i);
  end

  assign raw_hazard_present_o = decoded_uop_valid_i &&
                                (execute_writes_rs1 || execute_writes_rs2 ||
                                 writeback_writes_rs1 || writeback_writes_rs2);

  assign older_instruction_present = execute_uop_valid_i || writeback_result_valid_i || lsu_busy_i;
  assign older_serializing_instruction_present =
      (execute_uop_valid_i && execute_serializing_i) ||
      (writeback_result_valid_i && writeback_serializing_i);

  // 串行化指令必须等所有老指令离开后端后才能进入；进入后又阻止年轻指令，直到自己提交。
  assign serializing_hazard_present_o = decoded_uop_valid_i &&
      (older_serializing_instruction_present ||
       (decoded_serializing_i && older_instruction_present));

  assign structural_hazard_present_o = lsu_busy_i;
  assign control_recovery_occurred = execute_redirect_occurred_i || commit_redirect_occurred_i;

  assign decode_accept_allowed_o = !raw_hazard_present_o &&
                                   !serializing_hazard_present_o &&
                                   !structural_hazard_present_o &&
                                   !control_recovery_occurred;

  // EX级redirect来自当前正在执行的分支自身，不能阻止该分支进入WB；commit级redirect
  // 来自更老指令，必须阻止当前年轻EX指令产生completion或访存副作用。
  assign execute_issue_allowed_o = !structural_hazard_present_o && !commit_redirect_occurred_i;

  assign decode_execute_flush_o = control_recovery_occurred;
  assign writeback_flush_o = commit_redirect_occurred_i;

`ifndef SYNTHESIS
  /* verilator lint_off SYNCASYNCNET */
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    raw_hazard_present_o |-> !decode_accept_allowed_o)
  else $error("pipeline accepted a decoded instruction with an unresolved RAW hazard");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    control_recovery_occurred |-> decode_execute_flush_o)
  else $error("pipeline recovery did not flush the ID/EX stage");
  /* verilator lint_on SYNCASYNCNET */
`endif

endmodule
