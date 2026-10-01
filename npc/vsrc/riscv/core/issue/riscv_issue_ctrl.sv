// 发射前的依赖与操作数选择。已发射生产者由 scoreboard 查询，ID/EX 中尚未发射者单独检查。
module riscv_issue_ctrl
  import riscv_pkg::*;
(
    input  decoded_uop_t             decoded_uop_i,
    input  logic                     decoded_uop_valid_i,
    input  xlen_data_t               register_rs1_i,
    input  xlen_data_t               register_rs2_i,
    input  execute_packet_t          execute_packet_i,
    input  logic                     execute_packet_valid_i,
    input  execute_result_t          execute_result_i,
    input  logic                     scoreboard_rs1_pending_i,
    input  logic                     scoreboard_rs1_ready_i,
    input  xlen_data_t               scoreboard_rs1_value_i,
    input  logic                     scoreboard_rs2_pending_i,
    input  logic                     scoreboard_rs2_ready_i,
    input  xlen_data_t               scoreboard_rs2_value_i,
    input  logic                     scoreboard_serializing_present_i,
    input  logic                     scoreboard_empty_i,
    input  logic                     scoreboard_allocate_ready_i,
    input  logic                     scoreboard_memory_issue_allowed_i,
    input  logic                     recovery_i,
    input  logic                     execute_operands_ready_i,
    input  scoreboard_index_t        allocate_index_i,
    input  scoreboard_index_t        scoreboard_rs1_index_i,
    input  scoreboard_index_t        scoreboard_rs2_index_i,
    input  completion_source_e       scoreboard_rs1_source_i,
    input  completion_source_e       scoreboard_rs2_source_i,
    output completion_source_e       operand_source_o                 [2],
    output logic               [1:0] operand_pending_o,
    output scoreboard_index_t        operand_index_o                  [2],
    output xlen_data_t               rs1_value_o,
    output xlen_data_t               rs2_value_o,
    output logic                     decode_accept_allowed_o,
    output logic                     execute_issue_allowed_o,
    output logic                     raw_hazard_present_o,
    output logic                     serializing_hazard_present_o,
    output logic                     structural_hazard_present_o
);
  logic pending_writer_present;
  logic pending_result_available;
  logic pending_writes_rs1;
  logic pending_writes_rs2;
  logic rs1_waiting;
  logic rs2_waiting;
  logic serializing_waiting;
  logic memory_issue_waiting;

  assign pending_writer_present = execute_packet_valid_i && execute_packet_i.uop.writes_rd &&
      execute_packet_i.uop.rd != '0;
  assign pending_result_available = execute_operands_ready_i && !execute_result_i.uop.exception_valid &&
      (execute_packet_i.uop.fu_type inside {FU_INT, FU_BRANCH});
  assign pending_writes_rs1 = pending_writer_present && decoded_uop_i.uses_rs1 &&
      decoded_uop_i.rs1 == execute_packet_i.uop.rd;
  assign pending_writes_rs2 = pending_writer_present && decoded_uop_i.uses_rs2 &&
      decoded_uop_i.rs2 == execute_packet_i.uop.rd;
  assign rs1_waiting = pending_writes_rs1 ? !pending_result_available :
      (scoreboard_rs1_pending_i && !scoreboard_rs1_ready_i);
  assign rs2_waiting = pending_writes_rs2 ? !pending_result_available :
      (scoreboard_rs2_pending_i && !scoreboard_rs2_ready_i);
  assign rs1_value_o = pending_writes_rs1 ? execute_result_i.result :
      (scoreboard_rs1_pending_i ? scoreboard_rs1_value_i : register_rs1_i);
  assign rs2_value_o = pending_writes_rs2 ? execute_result_i.result :
      (scoreboard_rs2_pending_i ? scoreboard_rs2_value_i : register_rs2_i);
  assign serializing_waiting = scoreboard_serializing_present_i ||
      (execute_packet_valid_i && execute_packet_i.uop.serializing) ||
      (decoded_uop_i.serializing && (execute_packet_valid_i || !scoreboard_empty_i));
  assign memory_issue_waiting = execute_packet_i.uop.fu_type == FU_LSU &&
      !scoreboard_memory_issue_allowed_i;

  // ready 不依赖 decoded valid 或前端 flush，避免反馈成组合环。
  // 依赖可以进入现有 ID/EX 槽等待；年轻指令仍不能越过该槽。
  assign operand_pending_o = {rs2_waiting, rs1_waiting};
  assign operand_index_o[0] = pending_writes_rs1 ? allocate_index_i : scoreboard_rs1_index_i;
  assign operand_index_o[1] = pending_writes_rs2 ? allocate_index_i : scoreboard_rs2_index_i;
  assign operand_source_o[0] = pending_writes_rs1 ? completion_source(
      execute_packet_i.uop
  ) : scoreboard_rs1_source_i;
  assign operand_source_o[1] = pending_writes_rs2 ? completion_source(
      execute_packet_i.uop
  ) : scoreboard_rs2_source_i;
  assign decode_accept_allowed_o = !serializing_waiting;
  assign execute_issue_allowed_o = scoreboard_allocate_ready_i && execute_operands_ready_i && !memory_issue_waiting && !recovery_i;
  assign raw_hazard_present_o = execute_packet_valid_i && !execute_operands_ready_i;
  assign serializing_hazard_present_o = decoded_uop_valid_i && serializing_waiting;
  assign structural_hazard_present_o = !scoreboard_allocate_ready_i ||
      (execute_packet_valid_i && memory_issue_waiting);
endmodule
