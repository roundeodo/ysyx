module riscv32_exu
  import riscv32_pkg::*;
(
    input  execute_packet_t execute_packet_i,
    input  logic            execute_packet_valid_i,
    // valid只表示ID/EX中存在payload；issue_allowed决定本拍是否允许这条指令离开EX。
    // 它既门控LSU副作用，也门控普通EXU completion，保证年轻整数/控制流指令不能
    // 越过仍在LSU中的老指令提交。恢复只清valid，不修改宽payload。
    input  logic execute_packet_issue_allowed_i,
    output logic execute_packet_ready_o,

    output execute_result_t exu_result_o,
    output logic            exu_result_valid_o,
    input  logic            exu_result_ready_i,

    output lsu_req_t lsu_req_o,
    output logic     lsu_req_valid_o,
    input  logic     lsu_req_ready_i
);
  // EXU应只依赖ISA架构宽度；物理地址宽度和AXI数据宽度都不应进入ALU。这样将来把
  // 地址翻译放到AGU/MMU、把总线加宽时，不会迫使整数执行单元一起修改。
  localparam int unsigned SHIFT_AMOUNT_WIDTH = $clog2(XLEN);
  localparam int unsigned WORD_WIDTH = 32;
  localparam int unsigned WORD_SHIFT_WIDTH = $clog2(WORD_WIDTH);

  xlen_data_t execute_rs1_value;
  xlen_data_t execute_rs2_value;

  // operand_prepare 在消费者写入 ID/EX 时完成源选择与前递。EX 只消费寄存后的
  // 操作数，不再串联rd/rs比较、操作数选择或旁路mux。
  assign execute_rs1_value = execute_packet_i.source_a_value;
  assign execute_rs2_value = execute_packet_i.source_b_value;

  // 整数运算：主 ALU 与 32 位 word 运算并行，输出统一为 XLEN。
  xlen_data_t            alu_result;
  logic [WORD_WIDTH-1:0] word_result;

  // RV64的*W指令只在低32位中完成运算，再把32位结果符号扩展到XLEN。这里保留独立的
  // word-result通路，避免依赖宽位加法后的赋值截断，也明确约束寄存器型移位只使用
  // rs2[4:0]。因此rs2=32等价于移位0位，而非法的立即数shamt=32已由IDU拒绝。
  always_comb begin
    word_result = '0;
    unique case (execute_packet_i.uop.int_ctrl.op)
      ALU_ADDW: word_result = execute_rs1_value[WORD_WIDTH-1:0] + execute_rs2_value[WORD_WIDTH-1:0];
      ALU_SUBW: word_result = execute_rs1_value[WORD_WIDTH-1:0] - execute_rs2_value[WORD_WIDTH-1:0];
      ALU_SLLW: word_result = execute_rs1_value[WORD_WIDTH-1:0] << execute_rs2_value[WORD_SHIFT_WIDTH-1:0];
      ALU_SRLW: word_result = execute_rs1_value[WORD_WIDTH-1:0] >> execute_rs2_value[WORD_SHIFT_WIDTH-1:0];
      ALU_SRAW:
        word_result = $signed(execute_rs1_value[WORD_WIDTH-1:0]) >>> execute_rs2_value[WORD_SHIFT_WIDTH-1:0];
      default: word_result = '0;
    endcase
  end

  always_comb begin
    alu_result = '0;
    unique case (execute_packet_i.uop.int_ctrl.op)
      ALU_ADD: alu_result = execute_rs1_value + execute_rs2_value;
      ALU_SUB: alu_result = execute_rs1_value - execute_rs2_value;
      ALU_SLL: alu_result = execute_rs1_value << execute_rs2_value[SHIFT_AMOUNT_WIDTH-1:0];
      ALU_SLT: alu_result[0] = $signed(execute_rs1_value) < $signed(execute_rs2_value);
      ALU_SLTU: alu_result[0] = execute_rs1_value < execute_rs2_value;
      ALU_XOR: alu_result = execute_rs1_value ^ execute_rs2_value;
      ALU_SRL: alu_result = execute_rs1_value >> execute_rs2_value[SHIFT_AMOUNT_WIDTH-1:0];
      ALU_SRA: alu_result = $signed(execute_rs1_value) >>> execute_rs2_value[SHIFT_AMOUNT_WIDTH-1:0];
      ALU_OR: alu_result = execute_rs1_value | execute_rs2_value;
      ALU_AND: alu_result = execute_rs1_value & execute_rs2_value;
      ALU_ADDW, ALU_SUBW, ALU_SLLW, ALU_SRLW, ALU_SRAW:
        alu_result = {{(XLEN - WORD_WIDTH) {word_result[WORD_WIDTH-1]}}, word_result};
      default: alu_result = '0;
    endcase
  end

  // 控制流：比较 → 目标地址 → 实际后继与对齐检查。
  logic             branch_condition_met;
  logic             branch_taken;
  program_counter_t branch_target;
  program_counter_t sequential_next_pc;
  program_counter_t actual_next_pc;
  logic             branch_target_misaligned;

  always_comb begin
    unique case (execute_packet_i.uop.branch_ctrl.condition)
      BR_BEQ:  branch_condition_met = execute_rs1_value == execute_rs2_value;
      BR_BNE:  branch_condition_met = execute_rs1_value != execute_rs2_value;
      BR_BLT:  branch_condition_met = $signed(execute_rs1_value) < $signed(execute_rs2_value);
      BR_BGE:  branch_condition_met = $signed(execute_rs1_value) >= $signed(execute_rs2_value);
      BR_BLTU: branch_condition_met = execute_rs1_value < execute_rs2_value;
      BR_BGEU: branch_condition_met = execute_rs1_value >= execute_rs2_value;
      default: branch_condition_met = 1'b0;
    endcase
  end

  always_comb begin
    branch_taken  = 1'b0;
    branch_target = '0;

    unique case (execute_packet_i.uop.branch_ctrl.op)
      CF_BRANCH: begin
        branch_taken  = branch_condition_met;
        branch_target = execute_packet_i.uop.pc + execute_packet_i.uop.imm;
      end
      CF_JAL: begin
        branch_taken  = 1'b1;
        branch_target = execute_packet_i.uop.pc + execute_packet_i.uop.imm;
      end
      CF_JALR: begin
        branch_taken = 1'b1;
        // JALR只规定目标地址bit 0清零，不规定实现必须是32位。
        branch_target    = execute_rs1_value + execute_packet_i.uop.imm;
        branch_target[0] = 1'b0;
      end
      default: ;
    endcase
  end

  // 基础RV32I/RV64I未实现C扩展，所有控制流目标都必须4字节对齐。
  assign sequential_next_pc       = execute_packet_i.uop.pc + program_counter_t'(INSTRUCTION_BYTES);
  assign actual_next_pc           = branch_taken ? branch_target : sequential_next_pc;
  assign branch_target_misaligned = branch_taken && (branch_target[1:0] != 2'b00);

  // CSR 读值由译码级提供，此处只计算写回值。
  xlen_data_t csr_operand;
  xlen_data_t csr_wdata;

  assign csr_operand = execute_packet_i.uop.csr_ctrl.use_imm ?
      {{(XLEN-5){1'b0}}, execute_packet_i.uop.rs1} :
      execute_rs1_value;

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
  assign lsu_effective_addr = effective_addr_t'(execute_rs1_value + execute_packet_i.uop.imm);

  // 非访存结果汇合；异常指令在本出口撤销寄存器和 CSR 写副作用。
  execute_result_t exu_result;

  always_comb begin
    exu_result        = '0;
    exu_result.uop    = execute_packet_i.uop;
    exu_result.result = '0;
    // 不要使用32'd4，也不要使用I-cache line/取指口宽度。顺序下一条指令的位置由ISA指令
    // 长度决定；cache一次返回多少字节属于前端微架构，两者必须解耦。
    exu_result.next_pc   = sequential_next_pc;
    exu_result.csr_wdata = csr_wdata;
    // 预测校验位于后继EX/MEM寄存级之后。本级只计算真实next_pc，避免把预测比较继续
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
        exu_result.result = execute_packet_i.uop.pc + program_counter_t'(INSTRUCTION_BYTES);
      end
      FU_CSR:  exu_result.result = execute_packet_i.csr_rdata;
      default: ;
    endcase
  end

  always_comb begin
    lsu_req_o                = '0;
    lsu_req_o.uop            = execute_packet_i.uop;
    lsu_req_o.next_pc        = sequential_next_pc;
    lsu_req_o.effective_addr = lsu_effective_addr;
    lsu_req_o.store_data     = execute_rs2_value;
  end

  assign exu_result_o       = exu_result;
  assign exu_result_valid_o = execute_packet_valid_i && execute_packet_issue_allowed_i &&
      (execute_packet_i.uop.fu_type != FU_LSU);
  // LSU请求一旦握手就可能产生架构可见的访存副作用，因此同样在接口边界检查
  // issue_allowed；被阻塞或恢复取消的指令不能依赖下游valid-only squash补救。
  assign lsu_req_valid_o = execute_packet_valid_i && execute_packet_issue_allowed_i &&
      (execute_packet_i.uop.fu_type == FU_LSU);
  assign execute_packet_ready_o = (execute_packet_i.uop.fu_type == FU_LSU) ?
      lsu_req_ready_i : exu_result_ready_i;

`ifndef SYNTHESIS
  always_comb begin : check_exception_side_effects
    if (exu_result_valid_o && exu_result_o.uop.exception_valid) begin
      assert (!exu_result_o.redirect_valid && !exu_result_o.uop.writes_rd)
      else
        $error("EXU exception retained a redirect or destination-register side effect");
    end

    if (execute_packet_valid_i && !execute_packet_issue_allowed_i) begin
      assert (!exu_result_valid_o && !lsu_req_valid_o)
      else
        $error("EXU emitted a completion while issue was blocked");
    end
  end
`endif

endmodule
