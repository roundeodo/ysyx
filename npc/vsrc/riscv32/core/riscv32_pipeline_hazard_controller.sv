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

    input logic          execute_uop_valid_i,
    input logic          execute_writes_rd_i,
    input arch_reg_idx_t execute_rd_i,
    input logic          execute_serializing_i,
    input logic          execute_forwarding_available_i,

    // 单项completion queue中的EX结果比在途LSU年轻、比当前EX年老。它是独立的
    // 流水级生产者，不能只在数据mux中处理而遗漏RAW和串行化判断。
    input logic          buffered_exu_result_present_i,
    input logic          buffered_exu_writes_rd_i,
    input arch_reg_idx_t buffered_exu_rd_i,
    input logic          buffered_exu_serializing_i,
    input logic          buffered_exu_forwarding_available_i,

    input logic          writeback_result_valid_i,
    input logic          writeback_writes_rd_i,
    input arch_reg_idx_t writeback_rd_i,
    input logic          writeback_serializing_i,
    input logic          writeback_forwarding_available_i,

    // 在途LSU事务位于EX与WB之间。目的寄存器必须参与RAW比较；response出现时可直接前递，
    // 否则依赖指令停在ID。独立指令允许进入EX等待，从而避免把LSU busy做成全前端闸门。
    input logic          lsu_busy_i,
    input logic          lsu_pending_writes_rd_i,
    input arch_reg_idx_t lsu_pending_rd_i,
    input logic          lsu_forwarding_available_i,

    input logic execute_redirect_occurred_i,
    input logic commit_redirect_occurred_i,

    output logic decode_accept_allowed_o,
    output logic execute_issue_allowed_o,
    output logic decode_execute_flush_o,
    output logic writeback_flush_o,

    output logic raw_hazard_present_o,
    output logic serializing_hazard_present_o,
    output logic structural_hazard_present_o,

    output logic rs1_execute_forwarding_selected_o,
    output logic rs1_buffered_exu_forwarding_selected_o,
    output logic rs1_lsu_forwarding_selected_o,
    output logic rs1_writeback_forwarding_selected_o,
    output logic rs2_execute_forwarding_selected_o,
    output logic rs2_buffered_exu_forwarding_selected_o,
    output logic rs2_lsu_forwarding_selected_o,
    output logic rs2_writeback_forwarding_selected_o
);

  logic execute_writes_rs1;
  logic execute_writes_rs2;
  logic buffered_exu_writes_rs1;
  logic buffered_exu_writes_rs2;
  logic writeback_writes_rs1;
  logic writeback_writes_rs2;
  logic lsu_writes_rs1;
  logic lsu_writes_rs2;
  logic rs1_value_unavailable;
  logic rs2_value_unavailable;
  logic older_serializing_instruction_present;
  logic older_instruction_present;
  logic control_recovery_occurred;

  always_comb begin
    execute_writes_rs1 = decoded_uop_valid_i && execute_uop_valid_i && execute_writes_rd_i &&
                         (execute_rd_i != '0) && decoded_uses_rs1_i &&
                         (execute_rd_i == decoded_rs1_i);
    execute_writes_rs2 = decoded_uop_valid_i && execute_uop_valid_i && execute_writes_rd_i &&
                         (execute_rd_i != '0) && decoded_uses_rs2_i &&
                         (execute_rd_i == decoded_rs2_i);

    buffered_exu_writes_rs1 = decoded_uop_valid_i && buffered_exu_result_present_i &&
                              buffered_exu_writes_rd_i && (buffered_exu_rd_i != '0) &&
                              decoded_uses_rs1_i && (buffered_exu_rd_i == decoded_rs1_i);
    buffered_exu_writes_rs2 = decoded_uop_valid_i && buffered_exu_result_present_i &&
                              buffered_exu_writes_rd_i && (buffered_exu_rd_i != '0) &&
                              decoded_uses_rs2_i && (buffered_exu_rd_i == decoded_rs2_i);

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
    rs1_execute_forwarding_selected_o = execute_writes_rs1 &&
                                        execute_forwarding_available_i;
    rs1_buffered_exu_forwarding_selected_o = !execute_writes_rs1 &&
                                              buffered_exu_writes_rs1 &&
                                              buffered_exu_forwarding_available_i;
    rs1_lsu_forwarding_selected_o = !execute_writes_rs1 && !buffered_exu_writes_rs1 &&
                                    lsu_writes_rs1 &&
                                    lsu_forwarding_available_i;
    rs1_writeback_forwarding_selected_o = !execute_writes_rs1 &&
                                          !buffered_exu_writes_rs1 && !lsu_writes_rs1 &&
                                          writeback_writes_rs1 &&
                                          writeback_forwarding_available_i;
    rs2_execute_forwarding_selected_o = execute_writes_rs2 &&
                                        execute_forwarding_available_i;
    rs2_buffered_exu_forwarding_selected_o = !execute_writes_rs2 &&
                                              buffered_exu_writes_rs2 &&
                                              buffered_exu_forwarding_available_i;
    rs2_lsu_forwarding_selected_o = !execute_writes_rs2 && !buffered_exu_writes_rs2 &&
                                    lsu_writes_rs2 &&
                                    lsu_forwarding_available_i;
    rs2_writeback_forwarding_selected_o = !execute_writes_rs2 &&
                                          !buffered_exu_writes_rs2 && !lsu_writes_rs2 &&
                                          writeback_writes_rs2 &&
                                          writeback_forwarding_available_i;

    rs1_value_unavailable = (execute_writes_rs1 && !execute_forwarding_available_i) ||
                            (!execute_writes_rs1 && buffered_exu_writes_rs1 &&
                             !buffered_exu_forwarding_available_i) ||
                            (!execute_writes_rs1 && !buffered_exu_writes_rs1 &&
                             lsu_writes_rs1 &&
                             !lsu_forwarding_available_i) ||
                            (!execute_writes_rs1 && !buffered_exu_writes_rs1 &&
                             !lsu_writes_rs1 &&
                             writeback_writes_rs1 &&
                             !writeback_forwarding_available_i);
    rs2_value_unavailable = (execute_writes_rs2 && !execute_forwarding_available_i) ||
                            (!execute_writes_rs2 && buffered_exu_writes_rs2 &&
                             !buffered_exu_forwarding_available_i) ||
                            (!execute_writes_rs2 && !buffered_exu_writes_rs2 &&
                             lsu_writes_rs2 &&
                             !lsu_forwarding_available_i) ||
                            (!execute_writes_rs2 && !buffered_exu_writes_rs2 &&
                             !lsu_writes_rs2 &&
                             writeback_writes_rs2 &&
                             !writeback_forwarding_available_i);
  end

  assign raw_hazard_present_o = decoded_uop_valid_i &&
                                (rs1_value_unavailable || rs2_value_unavailable);

  assign older_instruction_present = execute_uop_valid_i || buffered_exu_result_present_i ||
                                     writeback_result_valid_i || lsu_busy_i;
  assign older_serializing_instruction_present =
      (execute_uop_valid_i && execute_serializing_i) ||
      (buffered_exu_result_present_i && buffered_exu_serializing_i) ||
      (writeback_result_valid_i && writeback_serializing_i);

  // 串行化指令必须等所有老指令离开后端后才能进入；进入后又阻止年轻指令，直到自己提交。
  assign serializing_hazard_present_o = decoded_uop_valid_i &&
      (older_serializing_instruction_present ||
       (decoded_serializing_i && older_instruction_present));

  assign structural_hazard_present_o = lsu_busy_i;
  assign control_recovery_occurred = execute_redirect_occurred_i || commit_redirect_occurred_i;

  assign decode_accept_allowed_o = !raw_hazard_present_o &&
                                   !serializing_hazard_present_o &&
                                   !control_recovery_occurred;

  // LSU自身的ready和completion年龄门控决定EX能否离开；hazard controller不再用busy阻止
  // 独立指令提前驻留EX。恢复事件仍必须禁止任何年轻completion或访存副作用。
  assign execute_issue_allowed_o = !control_recovery_occurred;

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

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    $onehot0({rs1_execute_forwarding_selected_o, rs1_buffered_exu_forwarding_selected_o,
              rs1_lsu_forwarding_selected_o,
              rs1_writeback_forwarding_selected_o}) &&
    $onehot0({rs2_execute_forwarding_selected_o, rs2_buffered_exu_forwarding_selected_o,
              rs2_lsu_forwarding_selected_o,
              rs2_writeback_forwarding_selected_o}))
  else $error("pipeline selected multiple forwarding producers for one source operand");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (decoded_uop_valid_i && execute_writes_rs1 && !execute_forwarding_available_i)
    |-> raw_hazard_present_o)
  else $error("pipeline accepted stale rs1 data while the newest EX producer was unavailable");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (decoded_uop_valid_i && execute_writes_rs2 && !execute_forwarding_available_i)
    |-> raw_hazard_present_o)
  else $error("pipeline accepted stale rs2 data while the newest EX producer was unavailable");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (decoded_uop_valid_i && !execute_writes_rs1 && buffered_exu_writes_rs1 &&
     !buffered_exu_forwarding_available_i) |-> raw_hazard_present_o)
  else $error("pipeline accepted stale rs1 data while a buffered EX producer was unavailable");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (decoded_uop_valid_i && !execute_writes_rs1 && !buffered_exu_writes_rs1 &&
     lsu_writes_rs1 &&
     !lsu_forwarding_available_i) |-> raw_hazard_present_o)
  else $error("pipeline accepted stale rs1 data while an LSU producer was pending");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (decoded_uop_valid_i && !execute_writes_rs2 && buffered_exu_writes_rs2 &&
     !buffered_exu_forwarding_available_i) |-> raw_hazard_present_o)
  else $error("pipeline accepted stale rs2 data while a buffered EX producer was unavailable");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (decoded_uop_valid_i && !execute_writes_rs2 && !buffered_exu_writes_rs2 &&
     lsu_writes_rs2 &&
     !lsu_forwarding_available_i) |-> raw_hazard_present_o)
  else $error("pipeline accepted stale rs2 data while an LSU producer was pending");
  /* verilator lint_on SYNCASYNCNET */
`endif

endmodule
