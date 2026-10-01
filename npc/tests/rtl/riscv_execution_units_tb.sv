// 修改前的 ALU 表达式，仅作独立对照，不进入正式综合。
module riscv_alu_reference
  import riscv_pkg::*;
(
    input  alu_op_e    operation_i,
    input  xlen_data_t operand_a_i,
    operand_b_i,
    output xlen_data_t result_o
);
  localparam int unsigned SHIFT_AMOUNT_WIDTH = $clog2(XLEN);
  localparam int unsigned WORD_WIDTH = 32;
  localparam int unsigned WORD_SHIFT_WIDTH = 5;
  // 整数运算：主 ALU 与 32 位 word 运算并行，输出统一为 XLEN。

  logic [WORD_WIDTH-1:0] word_result;

  // RV64的*W指令只在低32位中完成运算，再把32位结果符号扩展到XLEN。这里保留独立的
  // word-result通路，避免依赖宽位加法后的赋值截断，也明确约束寄存器型移位只使用
  // rs2[4:0]。因此rs2=32等价于移位0位，而非法的立即数shamt=32已由IDU拒绝。
  always_comb begin
    word_result = '0;
    unique case (operation_i)
      ALU_ADDW: word_result = operand_a_i[WORD_WIDTH-1:0] + operand_b_i[WORD_WIDTH-1:0];
      ALU_SUBW: word_result = operand_a_i[WORD_WIDTH-1:0] - operand_b_i[WORD_WIDTH-1:0];
      ALU_SLLW: word_result = operand_a_i[WORD_WIDTH-1:0] << operand_b_i[WORD_SHIFT_WIDTH-1:0];
      ALU_SRLW: word_result = operand_a_i[WORD_WIDTH-1:0] >> operand_b_i[WORD_SHIFT_WIDTH-1:0];
      ALU_SRAW:
      word_result = $signed(operand_a_i[WORD_WIDTH-1:0]) >>> operand_b_i[WORD_SHIFT_WIDTH-1:0];
      default: word_result = '0;
    endcase
  end

  always_comb begin
    result_o = '0;
    unique case (operation_i)
      ALU_ADD: result_o = operand_a_i + operand_b_i;
      ALU_SUB: result_o = operand_a_i - operand_b_i;
      ALU_SLL: result_o = operand_a_i << operand_b_i[SHIFT_AMOUNT_WIDTH-1:0];
      ALU_SLT: result_o[0] = $signed(operand_a_i) < $signed(operand_b_i);
      ALU_SLTU: result_o[0] = operand_a_i < operand_b_i;
      ALU_XOR: result_o = operand_a_i ^ operand_b_i;
      ALU_SRL: result_o = operand_a_i >> operand_b_i[SHIFT_AMOUNT_WIDTH-1:0];
      ALU_SRA: result_o = $signed(operand_a_i) >>> operand_b_i[SHIFT_AMOUNT_WIDTH-1:0];
      ALU_OR: result_o = operand_a_i | operand_b_i;
      ALU_AND: result_o = operand_a_i & operand_b_i;
      ALU_ADDW, ALU_SUBW, ALU_SLLW, ALU_SRLW, ALU_SRAW:
      result_o = {{(XLEN - WORD_WIDTH) {word_result[WORD_WIDTH-1]}}, word_result};
      default: result_o = '0;
    endcase
  end

endmodule

// C++ 驱动时钟及请求，算术期望由 Python 大整数计算；本模块只连接实际 RTL。
module riscv_execution_units_tb
  import riscv_pkg::*;
(
    input  logic                                         clk_i,
    rst_ni,
    flush_i,
    input  logic [                                 63:0] operand_a_i,
    operand_b_i,
    input  logic [                                  3:0] alu_operation_i,
    output logic [                                 63:0] alu_result_o,
    alu_reference_o,
    input  logic                                         unit_divide_i,
    input  logic [                                  2:0] unit_operation_i,
    input  logic                                         unit_word_i,
    unit_request_valid_i,
    output logic                                         unit_request_ready_o,
    output logic [                                 63:0] unit_result_o,
    output logic                                         unit_result_valid_o,
    input  logic                                         unit_result_ready_i,
    input  logic [                                  1:0] branch_operation_i,
    input  logic [                                  2:0] branch_condition_i,
    input  logic [                                 63:0] pc_i,
    immediate_i,
    output logic [                                 63:0] branch_target_o,
    branch_next_pc_o,
    output logic                                         branch_misaligned_o,
    input  logic [                                 31:0] instruction_i,
    output int unsigned scoreboard_entry_count_o,
    input  logic [riscv_pkg::SCOREBOARD_INDEX_WIDTH-1:0] unit_request_index_i,
    output logic [riscv_pkg::SCOREBOARD_INDEX_WIDTH-1:0] unit_result_index_o,
    input  logic [riscv_pkg::SCOREBOARD_INDEX_WIDTH-1:0] exu_request_index_i,
    output logic [riscv_pkg::SCOREBOARD_INDEX_WIDTH-1:0] exu_result_index_o,
    input  logic                                         exu_request_valid_i,
    exu_issue_allowed_i,
    exu_result_ready_i,
    output logic                                         exu_request_ready_o,
    exu_result_valid_o,
    exu_forwardable_o,
    output logic [                                 63:0] exu_result_o,
    output logic                                         exu_exception_o,
    decode_exception_o,
    output logic [                                  2:0] decode_fu_o,
    decode_operation_o,
    output logic                                         decode_word_o,
    input  logic                                         prediction_error_i,
    input  logic                                         pipeline_request_valid_i,
    input  logic                                         pipeline_issue_allowed_i,
    input  logic                                         pipeline_result_ready_i,
    output logic                                         pipeline_request_ready_o,
    output logic                                         pipeline_packet_present_o,
    output logic                                         pipeline_redirect_valid_o,
    output logic                                         pipeline_result_valid_o,
    output logic [                                 63:0] pipeline_result_o
);

  assign scoreboard_entry_count_o = riscv_config_pkg::SCOREBOARD_ENTRY_COUNT;
  riscv_alu u_alu (
      .operation_i(alu_op_e'(alu_operation_i)),
      .operand_a_i(operand_a_i),
      .operand_b_i(operand_b_i),
      .result_o(alu_result_o)
  );
  riscv_alu_reference u_reference (
      .operation_i(alu_op_e'(alu_operation_i)),
      .operand_a_i(operand_a_i),
      .operand_b_i(operand_b_i),
      .result_o(alu_reference_o)
  );
  branch_uop_ctrl_t branch_control;
  assign branch_control.op        = control_flow_op_e'(branch_operation_i);
  assign branch_control.condition = branch_cond_e'(branch_condition_i);
  riscv_branch_unit u_branch (
      .operation_i(branch_control),
      .instruction_pc_i(pc_i),
      .operand_a_i(operand_a_i),
      .operand_b_i(operand_b_i),
      .immediate_i(immediate_i),
      .sequential_pc_o(),
      .target_pc_o(branch_target_o),
      .next_pc_o(branch_next_pc_o),
      .target_misaligned_o(branch_misaligned_o)
  );
  muldiv_ctrl_t unit_control;
  assign unit_control.op             = muldiv_op_e'(unit_operation_i);
  assign unit_control.word_operation = unit_word_i;
  logic multiply_ready, divide_ready, multiply_valid, divide_valid;
  xlen_data_t multiply_result, divide_result;
  scoreboard_index_t multiply_index, divide_index;
  riscv_multiplier u_multiplier (
      .clk_i(clk_i),
      .rst_ni(rst_ni),
      .flush_i(flush_i),
      .request_index_i(unit_request_index_i),
      .result_index_o(multiply_index),
      .request_operation_i(unit_control),
      .request_operand_a_i(operand_a_i),
      .request_operand_b_i(operand_b_i),
      .request_valid_i(unit_request_valid_i && !unit_divide_i),
      .request_ready_o(multiply_ready),
      .result_o(multiply_result),
      .result_present_o(),
      .result_valid_o(multiply_valid),
      .result_ready_i(unit_result_ready_i && !unit_divide_i)
  );
  riscv_divider u_divider (
      .clk_i(clk_i),
      .rst_ni(rst_ni),
      .flush_i(flush_i),
      .request_index_i(unit_request_index_i),
      .result_index_o(divide_index),
      .request_operation_i(unit_control),
      .request_operand_a_i(operand_a_i),
      .request_operand_b_i(operand_b_i),
      .request_valid_i(unit_request_valid_i && unit_divide_i),
      .request_ready_o(divide_ready),
      .result_o(divide_result),
      .result_present_o(),
      .result_valid_o(divide_valid),
      .result_ready_i(unit_result_ready_i && unit_divide_i)
  );
  assign unit_request_ready_o = unit_divide_i ? divide_ready : multiply_ready;
  assign unit_result_valid_o  = unit_divide_i ? divide_valid : multiply_valid;
  assign unit_result_index_o  = unit_divide_i ? divide_index : multiply_index;
  assign unit_result_o        = unit_divide_i ? divide_result : multiply_result;

  fetch_entry_t fetch_entry;
  decoded_uop_t decoded_uop;
  execute_packet_t execute_packet;
  execute_result_t execute_result;
  always_comb begin
    fetch_entry                             = '0;
    fetch_entry.pc                          = pc_i;
    fetch_entry.instruction                 = instruction_i;
    fetch_entry.prediction.predicted_taken  = prediction_error_i;
    fetch_entry.prediction.predicted_target = pc_i + 64'd64;
    execute_packet                          = '0;
    execute_packet.uop                      = decoded_uop;
    execute_packet.source_a_value           = operand_a_i;
    execute_packet.source_b_value           = operand_b_i;
  end
  riscv_idu u_idu (
      .fetch_entry_i(fetch_entry),
      .fetch_entry_valid_i(exu_request_valid_i || pipeline_request_valid_i),
      .fetch_entry_ready_o(),
      .decoded_uop_o(decoded_uop),
      .decoded_uop_valid_o(),
      .decoded_uop_ready_i(exu_request_ready_o)
  );
  assign decode_fu_o        = decoded_uop.fu_type;
  assign decode_operation_o = decoded_uop.muldiv_ctrl.op;
  assign decode_word_o      = decoded_uop.muldiv_ctrl.word_operation;
  assign decode_exception_o = decoded_uop.exception_valid;
  arithmetic_result_t exu_multiply_result, exu_divide_result;
  logic exu_multiply_valid, exu_divide_valid, exu_normal_valid;
  riscv_exu u_exu (
      .clk_i(clk_i),
      .rst_ni(rst_ni),
      .flush_i(flush_i),
      .issue_flush_i(flush_i),
      .scoreboard_index_i(exu_request_index_i),
      .multiply_result_o(exu_multiply_result),
      .multiply_result_valid_o(exu_multiply_valid),
      .multiply_result_present_o(),
      .multiply_result_ready_i(exu_result_ready_i),
      .divide_result_o(exu_divide_result),
      .divide_result_valid_o(exu_divide_valid),
      .divide_result_present_o(),
      .divide_result_ready_i(exu_result_ready_i),
      .execute_packet_i(execute_packet),
      .arithmetic_operand_i('{execute_packet.source_a_value, execute_packet.source_b_value}),
      .execute_packet_valid_i(exu_request_valid_i),
      .execute_packet_issue_allowed_i(exu_issue_allowed_i),
      .execute_packet_ready_o(exu_request_ready_o),
      .exu_result_o(execute_result),
      .exu_result_valid_o(exu_normal_valid),
      .exu_result_ready_i(exu_result_ready_i),
      .lsu_req_o(),
      .lsu_req_valid_o(),
      .lsu_req_ready_i(1'b1),
      .sequential_redirect_o(),
      .sequential_redirect_valid_o()
  );
  assign exu_result_valid_o = exu_normal_valid || exu_multiply_valid || exu_divide_valid;
  assign exu_result_index_o = exu_divide_valid ? exu_divide_result.scoreboard_index :
      (exu_multiply_valid ? exu_multiply_result.scoreboard_index : execute_result.scoreboard_index);
  assign exu_forwardable_o = exu_result_valid_o;
  assign exu_result_o = exu_divide_valid ? exu_divide_result.result :
      (exu_multiply_valid ? exu_multiply_result.result : execute_result.result);
  assign exu_exception_o = execute_result.uop.exception_valid;
  // 实际 ID/EX 与 EXU：检查提前纠错时当前指令保持及年轻输入取消。
  execute_packet_t pipeline_packet;
  execute_result_t pipeline_result;
  logic pipeline_execute_ready;
  logic pipeline_advance;
  assign pipeline_advance = pipeline_execute_ready && pipeline_issue_allowed_i;
  riscv_id_ex_reg u_pipeline_register (
      .arithmetic_operand_o(),
      .operand_pending_i('0), .operand_index_i('{default:'0}),
      .operand_source_i('{default:COMPLETION_LSU}),
      .completion_i('{default:'0}), .completion_valid_i('0), .operands_ready_o(),
      .clk_i(clk_i),
      .rst_ni(rst_ni),
      .decoded_execute_packet_i(execute_packet),
      .decoded_execute_packet_valid_i(pipeline_request_valid_i),
      .decoded_execute_packet_ready_o(pipeline_request_ready_o),
      .execute_packet_o(pipeline_packet),
      .execute_packet_valid_o(pipeline_packet_present_o),
      .execute_packet_ready_i(pipeline_advance),
      .execute_forwardable_producer_present_o(),
      .execute_blocking_producer_present_o(),
      .execute_serializing_instruction_present_o(),
      .flush_i(flush_i || (pipeline_redirect_valid_o && pipeline_advance))
  );
  arithmetic_result_t pipeline_multiply_result, pipeline_divide_result;
  logic pipeline_multiply_valid, pipeline_divide_valid, pipeline_normal_valid;
  riscv_exu u_pipeline_exu (
      .clk_i(clk_i),
      .rst_ni(rst_ni),
      .flush_i(flush_i),
      .issue_flush_i(flush_i),
      .scoreboard_index_i('0),
      .multiply_result_o(pipeline_multiply_result),
      .multiply_result_valid_o(pipeline_multiply_valid),
      .multiply_result_present_o(),
      .multiply_result_ready_i(pipeline_result_ready_i),
      .divide_result_o(pipeline_divide_result),
      .divide_result_valid_o(pipeline_divide_valid),
      .divide_result_present_o(),
      .divide_result_ready_i(pipeline_result_ready_i),
      .execute_packet_i(pipeline_packet),
      .arithmetic_operand_i('{pipeline_packet.source_a_value, pipeline_packet.source_b_value}),
      .execute_packet_valid_i(pipeline_packet_present_o),
      .execute_packet_issue_allowed_i(pipeline_issue_allowed_i),
      .execute_packet_ready_o(pipeline_execute_ready),
      .exu_result_o(pipeline_result),
      .exu_result_valid_o(pipeline_normal_valid),
      .exu_result_ready_i(pipeline_result_ready_i),
      .lsu_req_o(),
      .lsu_req_valid_o(),
      .lsu_req_ready_i(1'b1),
      .sequential_redirect_o(),
      .sequential_redirect_valid_o(pipeline_redirect_valid_o)
  );
  assign pipeline_result_valid_o = pipeline_normal_valid || pipeline_multiply_valid || pipeline_divide_valid;
  assign pipeline_result_o = pipeline_divide_valid ? pipeline_divide_result.result :
      (pipeline_multiply_valid ? pipeline_multiply_result.result : pipeline_result.result);
endmodule
