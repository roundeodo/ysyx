module riscv_exu
  import riscv_pkg::*;
(
    input  logic               clk_i,
    input  logic               rst_ni,
    input  logic               flush_i,
    input  logic               issue_flush_i,
    input  scoreboard_index_t  scoreboard_index_i,
    output arithmetic_result_t multiply_result_o,
    output logic               multiply_result_valid_o,
    output logic               multiply_result_present_o,
    input  logic               multiply_result_ready_i,
    output arithmetic_result_t divide_result_o,
    output logic               divide_result_valid_o,
    output logic               divide_result_present_o,
    input  logic               divide_result_ready_i,

    input  execute_packet_t execute_packet_i,
    input  xlen_data_t      muldiv_operand_array_i        [2],
    input  logic            execute_packet_valid_i,
    // 请求在功能单元接收时离开 ID/EX；乘除结果通过独立返回口交付。
    input  logic            execute_packet_issue_allowed_i,
    output logic            execute_packet_ready_o,

    output execute_result_t exu_result_o,
    output logic            exu_result_valid_o,
    input  logic            exu_result_ready_i,

    output lsu_req_t lsu_req_o,
    output logic     lsu_req_valid_o,
    input  logic     lsu_req_ready_i,

    // 当前非分支发现预测错误时恢复顺序后继；不等待执行结果交付。
    output redirect_req_t sequential_redirect_o,
    output logic          sequential_redirect_valid_o
);
  // ID/EX 已保存语义操作数；单周期单元保持组合路径，不新增寄存边界。
  xlen_data_t execute_operand_a_value;
  xlen_data_t execute_operand_b_value;
  xlen_data_t alu_result;
  program_counter_t branch_target;
  program_counter_t sequential_next_pc;
  program_counter_t actual_next_pc;
  logic branch_target_misaligned;
  assign execute_operand_a_value = execute_packet_i.source_a_value;
  assign execute_operand_b_value = execute_packet_i.source_b_value;
  riscv_alu u_alu (
      .operation_i(execute_packet_i.uop.int_ctrl.op),
      .operand_a_i(execute_operand_a_value),
      .operand_b_i(execute_operand_b_value),
      .result_o   (alu_result)
  );
  riscv_branch_unit u_branch (
      .operation_i        (execute_packet_i.uop.branch_ctrl),
      .instruction_pc_i   (execute_packet_i.uop.pc),
      .operand_a_i        (execute_operand_a_value),
      .operand_b_i        (execute_operand_b_value),
      .immediate_i        (execute_packet_i.uop.imm),
      .sequential_pc_o    (sequential_next_pc),
      .target_pc_o        (branch_target),
      .next_pc_o          (actual_next_pc),
      .target_misaligned_o(branch_target_misaligned)
  );

  // 多周期单元各自持有算法状态与窄指令标识，发射位置不等待结果。
  logic muldiv_instruction;
  logic divide_operation;
  logic muldiv_request_valid;
  logic multiply_request_ready;
  logic divide_request_ready;
  assign muldiv_instruction = execute_packet_i.uop.fu_type == FU_MULDIV &&
      !execute_packet_i.uop.exception_valid;
  assign divide_operation = execute_packet_i.uop.muldiv_ctrl.op inside
      {MULDIV_DIV, MULDIV_DIVU, MULDIV_REM, MULDIV_REMU};
  assign muldiv_request_valid = execute_packet_valid_i && execute_packet_issue_allowed_i &&
      muldiv_instruction && !flush_i;

  riscv_multiplier u_multiplier (
      .clk_i              (clk_i),
      .rst_ni             (rst_ni),
      .flush_i            (flush_i),
      .request_index_i    (scoreboard_index_i),
      .result_index_o     (multiply_result_o.scoreboard_index),
      .request_operation_i(execute_packet_i.uop.muldiv_ctrl),
      .request_operand_a_i(muldiv_operand_array_i[0]),
      .request_operand_b_i(muldiv_operand_array_i[1]),
      .request_valid_i    (muldiv_request_valid && !divide_operation),
      .request_ready_o    (multiply_request_ready),
      .result_o           (multiply_result_o.result),
      .result_present_o   (multiply_result_present_o),
      .result_valid_o     (multiply_result_valid_o),
      .result_ready_i     (multiply_result_ready_i)
  );
  riscv_divider u_divider (
      .clk_i              (clk_i),
      .rst_ni             (rst_ni),
      .flush_i            (flush_i),
      .request_index_i    (scoreboard_index_i),
      .result_index_o     (divide_result_o.scoreboard_index),
      .request_operation_i(execute_packet_i.uop.muldiv_ctrl),
      .request_operand_a_i(muldiv_operand_array_i[0]),
      .request_operand_b_i(muldiv_operand_array_i[1]),
      .request_valid_i    (muldiv_request_valid && divide_operation),
      .request_ready_o    (divide_request_ready),
      .result_o           (divide_result_o.result),
      .result_present_o   (divide_result_present_o),
      .result_valid_o     (divide_result_valid_o),
      .result_ready_i     (divide_result_ready_i)
  );

  // CSR 读值由译码级提供，此处只计算写回值。
  xlen_data_t csr_operand;
  xlen_data_t csr_wdata;

  assign csr_operand = execute_packet_i.uop.csr_ctrl.use_imm ?
      {{(XLEN-5){1'b0}}, execute_packet_i.uop.rs1} :
      execute_operand_a_value;

  always_comb begin
    unique case (execute_packet_i.uop.csr_ctrl.op)
      CSR_OP_RW: csr_wdata = csr_operand;
      CSR_OP_RS: csr_wdata = execute_packet_i.csr_rdata | csr_operand;
      CSR_OP_RC: csr_wdata = execute_packet_i.csr_rdata & ~csr_operand;
      default:   csr_wdata = '0;
    endcase
  end

  // AGU 独立生成访存地址，不经过整数 ALU 的结果选择。
  effective_addr_t lsu_effective_addr;
  assign lsu_effective_addr = effective_addr_t'(execute_operand_a_value + execute_packet_i.uop.imm);

  always_comb begin
    lsu_req_o                  = '0;
    lsu_req_o.scoreboard_index = scoreboard_index_i;
    lsu_req_o.uop              = execute_packet_i.uop;
    lsu_req_o.next_pc          = sequential_next_pc;
    lsu_req_o.effective_addr   = lsu_effective_addr;
    lsu_req_o.store_data       = execute_operand_b_value;
  end
  // LSU请求一旦握手就可能产生架构可见的访存副作用，因此同样在接口边界检查
  // issue_allowed；被阻塞或恢复取消的指令不能依赖下游valid-only squash补救。
  assign lsu_req_valid_o = execute_packet_valid_i && execute_packet_issue_allowed_i &&
      (execute_packet_i.uop.fu_type == FU_LSU);
  // 非访存结果汇合；异常指令在本出口撤销寄存器和 CSR 写副作用。
  execute_result_t exu_result;

  always_comb begin
    exu_result                  = '0;
    exu_result.scoreboard_index = scoreboard_index_i;
    exu_result.uop              = execute_packet_i.uop;
    // 不要使用32'd4，也不要使用I-cache line/取指口宽度。顺序下一条指令的位置由ISA指令
    // 长度决定；cache一次返回多少字节属于前端微架构，两者必须解耦。
    exu_result.next_pc   = sequential_next_pc;
    exu_result.csr_wdata = csr_wdata;
    // 预测校验位于后继 EX 结果寄存级之后。本级只计算真实next_pc，避免把预测比较继续
    // 串在分支加法器之后。
    exu_result.redirect_valid = 1'b0;
    exu_result.redirect_req   = '0;

    if (!execute_packet_i.uop.exception_valid &&
        (execute_packet_i.uop.fu_type == FU_CSR) && execute_packet_i.csr_illegal) begin
      exu_result.uop.exception_valid       = 1'b1;
      exu_result.uop.exception_cause       = EXC_ILLEGAL_INSTRUCTION;
      exu_result.uop.exception_tval        = xlen_data_t'(execute_packet_i.uop.instruction);
      exu_result.uop.writes_rd             = 1'b0;
      exu_result.uop.csr_ctrl.write_enable = 1'b0;
    end

    if (!execute_packet_i.uop.exception_valid && branch_target_misaligned) begin
      exu_result.uop.exception_valid = 1'b1;
      exu_result.uop.exception_cause = EXC_INSTR_ADDR_MISALIGNED;
      exu_result.uop.exception_tval  = xlen_data_t'(branch_target);
      exu_result.uop.writes_rd       = 1'b0;
      exu_result.redirect_valid      = 1'b0;
    end

    if (execute_packet_i.uop.fu_type == FU_BRANCH) begin
      // next_pc始终记录真实架构后继；redirect只表示预测后继与它不一致。
      exu_result.next_pc = actual_next_pc;
    end

    unique case (execute_packet_i.uop.fu_type)
      FU_INT:  exu_result.result = alu_result;
      FU_BRANCH: begin
        exu_result.result = sequential_next_pc;
      end
      FU_CSR:  exu_result.result = execute_packet_i.csr_rdata;
      default: ;
    endcase
  end


  assign exu_result_o = exu_result;
  assign exu_result_valid_o = execute_packet_valid_i && execute_packet_issue_allowed_i &&
      (execute_packet_i.uop.fu_type != FU_LSU) &&
      !muldiv_instruction;
  assign execute_packet_ready_o = (execute_packet_i.uop.fu_type == FU_LSU) ?
      lsu_req_ready_i : (muldiv_instruction ?
      (divide_operation ? divide_request_ready : multiply_request_ready) : exu_result_ready_i);

  // 共用已译码的类型；只请求前端丢弃年轻项，core 保留尚未交付的当前项。
  always_comb begin
    sequential_redirect_o           = '0;
    sequential_redirect_o.target_pc = sequential_next_pc;
    sequential_redirect_o.source_pc = execute_packet_i.uop.pc;
    sequential_redirect_o.reason    = REDIRECT_NONBRANCH;
  end
  // 纠正取指方向不必等待执行端就绪；历史位避免保持中的同一指令重复纠错。
  // 较老恢复由 core 的 redirect mux 优先处理，执行副作用仍检查 issue_allowed。
  logic sequential_redirect_occurred_q;
  assign sequential_redirect_valid_o = execute_packet_valid_i && !sequential_redirect_occurred_q &&
      (execute_packet_i.uop.fu_type != FU_BRANCH) && !execute_packet_i.uop.exception_valid &&
      execute_packet_i.uop.prediction.predicted_taken &&
      (execute_packet_i.uop.prediction.predicted_target != sequential_next_pc);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) sequential_redirect_occurred_q <= 1'b0;
    else if (issue_flush_i || !execute_packet_valid_i ||
             (execute_packet_issue_allowed_i && execute_packet_ready_o))
      sequential_redirect_occurred_q <= 1'b0;
    else if (sequential_redirect_valid_o) sequential_redirect_occurred_q <= 1'b1;
  end

`ifndef SYNTHESIS
  always_comb begin : check_exception_side_effects
    if (exu_result_valid_o && exu_result_o.uop.exception_valid) begin
      assert (!exu_result_o.redirect_valid && !exu_result_o.uop.writes_rd)
      else $error("EXU exception retained a redirect or destination-register side effect");
    end

    if (execute_packet_valid_i && !execute_packet_issue_allowed_i) begin
      assert (!exu_result_valid_o && !lsu_req_valid_o)
      else $error("EXU emitted a completion while issue was blocked");
    end
  end
`endif

endmodule
