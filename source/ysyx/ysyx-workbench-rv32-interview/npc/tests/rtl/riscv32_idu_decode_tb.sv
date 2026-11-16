module riscv32_idu_decode_tb;
  import riscv32_pkg::*;

  fetch_entry_t fetch_entry;
  logic         fetch_entry_valid;
  logic         fetch_entry_ready;
  decoded_uop_t decoded_uop;
  logic         decoded_uop_valid;

  riscv32_idu u_idu (
      .fetch_entry_i(fetch_entry),
      .fetch_entry_valid_i(fetch_entry_valid),
      .fetch_entry_ready_o(fetch_entry_ready),
      .decoded_uop_o(decoded_uop),
      .decoded_uop_valid_o(decoded_uop_valid),
      .decoded_uop_ready_i(1'b1)
  );

  function automatic instruction_t encode_r(
      input logic [6:0] funct7_value,
      input logic [4:0] rs2_value,
      input logic [4:0] rs1_value,
      input logic [2:0] funct3_value,
      input logic [4:0] rd_value,
      input logic [6:0] opcode_value
  );
    return {funct7_value, rs2_value, rs1_value, funct3_value, rd_value, opcode_value};
  endfunction

  function automatic instruction_t encode_i(
      input logic [11:0] immediate,
      input logic [ 4:0] rs1_value,
      input logic [ 2:0] funct3_value,
      input logic [ 4:0] rd_value,
      input logic [ 6:0] opcode_value
  );
    return {immediate, rs1_value, funct3_value, rd_value, opcode_value};
  endfunction

  function automatic instruction_t encode_s(
      input logic [11:0] immediate,
      input logic [ 4:0] rs2_value,
      input logic [ 4:0] rs1_value,
      input logic [ 2:0] funct3_value,
      input logic [ 6:0] opcode_value
  );
    return {
      immediate[11:5], rs2_value, rs1_value, funct3_value, immediate[4:0], opcode_value
    };
  endfunction

  function automatic instruction_t encode_u(
      input logic [19:0] immediate_upper,
      input logic [ 4:0] rd_value,
      input logic [ 6:0] opcode_value
  );
    return {immediate_upper, rd_value, opcode_value};
  endfunction

  task automatic apply_instruction(input instruction_t instruction);
    fetch_entry             = '0;
    fetch_entry.pc          = program_counter_t'(32'h3000_0100);
    fetch_entry.instruction = instruction;
    fetch_entry_valid       = 1'b1;
    #1;
    assert (fetch_entry_ready && decoded_uop_valid)
      else $fatal(1, "IDU handshake propagation failed for instruction %08x", instruction);
  endtask

  task automatic expect_integer_op(input instruction_t instruction, input alu_op_e expected_op);
    apply_instruction(instruction);
    assert (!decoded_uop.exception_valid)
      else $fatal(1, "legal integer instruction rejected: %08x", instruction);
    assert (decoded_uop.fu_type == FU_INT && decoded_uop.int_ctrl.op == expected_op)
      else $fatal(1, "wrong integer semantic op for instruction %08x", instruction);
    assert (decoded_uop.writes_rd && decoded_uop.uses_rs1)
      else $fatal(1, "wrong integer register dependency for instruction %08x", instruction);
  endtask

  task automatic expect_load(
      input instruction_t instruction,
      input mem_size_e expected_size,
      input logic expected_unsigned_load
  );
    apply_instruction(instruction);
    assert (!decoded_uop.exception_valid)
      else $fatal(1, "legal load instruction rejected: %08x", instruction);
    assert (decoded_uop.fu_type == FU_LSU && decoded_uop.mem_ctrl.cmd == MEM_CMD_LOAD)
      else $fatal(1, "wrong load semantic command for instruction %08x", instruction);
    assert (decoded_uop.mem_ctrl.size == expected_size &&
            decoded_uop.mem_ctrl.unsigned_load == expected_unsigned_load)
      else $fatal(1, "wrong load size or extension rule for instruction %08x", instruction);
  endtask

  task automatic expect_store(input instruction_t instruction, input mem_size_e expected_size);
    apply_instruction(instruction);
    assert (!decoded_uop.exception_valid)
      else $fatal(1, "legal store instruction rejected: %08x", instruction);
    assert (decoded_uop.fu_type == FU_LSU && decoded_uop.mem_ctrl.cmd == MEM_CMD_STORE)
      else $fatal(1, "wrong store semantic command for instruction %08x", instruction);
    assert (decoded_uop.mem_ctrl.size == expected_size && decoded_uop.uses_rs1 &&
            decoded_uop.uses_rs2)
      else $fatal(1, "wrong store size or dependency for instruction %08x", instruction);
  endtask

  task automatic expect_illegal(input instruction_t instruction);
    apply_instruction(instruction);
    assert (decoded_uop.exception_valid &&
            decoded_uop.exception_cause == EXC_ILLEGAL_INSTRUCTION)
      else $fatal(1, "illegal instruction was not rejected: %08x", instruction);
    assert (decoded_uop.exception_tval == xlen_data_t'(instruction))
      else $fatal(1, "illegal instruction tval mismatch: %08x", instruction);
    assert (!decoded_uop.writes_rd && decoded_uop.mem_ctrl.cmd == MEM_CMD_NONE &&
            decoded_uop.branch_ctrl.op == CF_NONE && !decoded_uop.csr_ctrl.write_enable)
      else $fatal(1, "illegal instruction retained an architectural side effect: %08x", instruction);
  endtask

  task automatic expect_system_exception(
      input instruction_t instruction,
      input system_op_e expected_system_op,
      input exception_cause_e expected_cause
  );
    apply_instruction(instruction);
    assert (decoded_uop.exception_valid &&
            (decoded_uop.system_op == expected_system_op) &&
            (decoded_uop.exception_cause == expected_cause) &&
            (decoded_uop.exception_tval == '0))
      else $fatal(1, "system exception decode mismatch: instruction=%08x cause=%0d",
                  instruction, decoded_uop.exception_cause);
    assert (!decoded_uop.writes_rd && decoded_uop.mem_ctrl.cmd == MEM_CMD_NONE &&
            !decoded_uop.csr_ctrl.write_enable)
      else $fatal(1, "system exception retained an architectural side effect");
  endtask

  task automatic expect_fetch_exception_priority;
    fetch_entry                 = '0;
    fetch_entry.pc              = program_counter_t'(32'h3000_0200);
    // 该数据位型恰好是ECALL，但取指访问已经失败，IDU不得用cause 11覆盖IFU的cause 1。
    fetch_entry.instruction     = instruction_t'(32'h0000_0073);
    fetch_entry.exception_valid = 1'b1;
    fetch_entry.exception_cause = EXC_INSTR_ACCESS_FAULT;
    fetch_entry.exception_tval  = xlen_data_t'(32'h3000_0200);
    fetch_entry_valid           = 1'b1;
    #1;
    assert (decoded_uop_valid && decoded_uop.exception_valid &&
            (decoded_uop.exception_cause == EXC_INSTR_ACCESS_FAULT) &&
            (decoded_uop.exception_tval == xlen_data_t'(32'h3000_0200)))
      else $fatal(1, "IDU overwrote an older IFU exception");
    assert (!decoded_uop.writes_rd && decoded_uop.mem_ctrl.cmd == MEM_CMD_NONE &&
            !decoded_uop.csr_ctrl.write_enable)
      else $fatal(1, "IFU exception retained a decoded architectural side effect");
  endtask

  initial begin
    fetch_entry       = '0;
    fetch_entry_valid = 1'b0;

    // 两种配置都必须保留原有RV32I译码行为。
    expect_integer_op(encode_i(12'hfff, 5'd1, FUNCT3_ADD_SUB, 5'd2, OPCODE_OP_IMM), ALU_ADD);
    expect_integer_op(encode_i(12'h01f, 5'd1, FUNCT3_SLL, 5'd2, OPCODE_OP_IMM), ALU_SLL);
    expect_load(encode_i(12'h004, 5'd1, FUNCT3_LW, 5'd2, OPCODE_LOAD), MEM_SIZE_WORD, 1'b0);
    expect_store(encode_s(12'h008, 5'd2, 5'd1, FUNCT3_SW, OPCODE_STORE), MEM_SIZE_WORD);
    expect_system_exception(32'h0000_0073, SYS_ECALL, EXC_ECALL_M);
    expect_system_exception(32'h0010_0073, SYS_EBREAK, EXC_BREAKPOINT);
    apply_instruction(32'h0ff0_000f);
    assert(!decoded_uop.exception_valid && decoded_uop.system_op==SYS_FENCE && !decoded_uop.serializing)
      else $fatal(1,"in-order FENCE added a full backend serialization");
    apply_instruction(32'h0000_100f);
    assert(!decoded_uop.exception_valid && decoded_uop.system_op==SYS_FENCE_I && decoded_uop.serializing)
      else $fatal(1,"FENCE.I lost its maintenance serialization");
    expect_fetch_exception_priority();

`ifdef YSYX_RV64_SEQUENTIAL
    // OP-IMM-32：立即数算术和5位移位量分别验证。
    expect_integer_op(
        encode_i(12'hfff, 5'd1, FUNCT3_ADD_SUB, 5'd2, OPCODE_OP_IMM_32), ALU_ADDW);
    expect_integer_op(
        encode_i(12'h01f, 5'd1, FUNCT3_SLL, 5'd2, OPCODE_OP_IMM_32), ALU_SLLW);
    expect_integer_op(
        encode_i(12'h01f, 5'd1, FUNCT3_SRL_SRA, 5'd2, OPCODE_OP_IMM_32), ALU_SRLW);
    expect_integer_op(
        encode_i(12'h41f, 5'd1, FUNCT3_SRL_SRA, 5'd2, OPCODE_OP_IMM_32), ALU_SRAW);

    // OP-32：寄存器型32位结果操作必须保留独立的*W语义。
    expect_integer_op(
        encode_r(FUNCT7_BASE, 5'd3, 5'd1, FUNCT3_ADD_SUB, 5'd2, OPCODE_OP_32), ALU_ADDW);
    expect_integer_op(
        encode_r(FUNCT7_ALT, 5'd3, 5'd1, FUNCT3_ADD_SUB, 5'd2, OPCODE_OP_32), ALU_SUBW);
    expect_integer_op(
        encode_r(FUNCT7_BASE, 5'd3, 5'd1, FUNCT3_SLL, 5'd2, OPCODE_OP_32), ALU_SLLW);
    expect_integer_op(
        encode_r(FUNCT7_BASE, 5'd3, 5'd1, FUNCT3_SRL_SRA, 5'd2, OPCODE_OP_32), ALU_SRLW);
    expect_integer_op(
        encode_r(FUNCT7_ALT, 5'd3, 5'd1, FUNCT3_SRL_SRA, 5'd2, OPCODE_OP_32), ALU_SRAW);

    expect_load(encode_i(12'h010, 5'd1, FUNCT3_LWU, 5'd2, OPCODE_LOAD), MEM_SIZE_WORD, 1'b1);
    expect_load(encode_i(12'h018, 5'd1, FUNCT3_LD, 5'd2, OPCODE_LOAD), MEM_SIZE_DOUBLE, 1'b0);
    expect_store(encode_s(12'h020, 5'd2, 5'd1, FUNCT3_SD, OPCODE_STORE), MEM_SIZE_DOUBLE);

    // RV64普通移位允许6位shamt；这里覆盖旧funct7检查会错误拒绝的32和63。
    expect_integer_op(encode_i(12'h020, 5'd1, FUNCT3_SLL, 5'd2, OPCODE_OP_IMM), ALU_SLL);
    expect_integer_op(encode_i(12'h03f, 5'd1, FUNCT3_SRL_SRA, 5'd2, OPCODE_OP_IMM), ALU_SRL);
    expect_integer_op(encode_i(12'h43f, 5'd1, FUNCT3_SRL_SRA, 5'd2, OPCODE_OP_IMM), ALU_SRA);

    // *IW仍只有5位shamt；保留位或不支持的OP-32 funct3必须报非法指令。
    expect_illegal(encode_i(12'h020, 5'd1, FUNCT3_SLL, 5'd2, OPCODE_OP_IMM_32));
    expect_illegal(encode_r(FUNCT7_BASE, 5'd3, 5'd1, FUNCT3_AND, 5'd2, OPCODE_OP_32));

    apply_instruction(encode_u(20'h80000, 5'd2, OPCODE_LUI));
    assert (!decoded_uop.exception_valid && decoded_uop.imm == 64'hffff_ffff_8000_0000)
      else $fatal(1, "RV64 LUI immediate was not sign-extended");
    apply_instruction(encode_u(20'h80000, 5'd2, OPCODE_AUIPC));
    assert (!decoded_uop.exception_valid && decoded_uop.imm == 64'hffff_ffff_8000_0000)
      else $fatal(1, "RV64 AUIPC immediate was not sign-extended");
`else
    // RV32构建必须拒绝所有RV64专属主opcode和访存宽度。
    expect_illegal(encode_i(12'h001, 5'd1, FUNCT3_ADD_SUB, 5'd2, OPCODE_OP_IMM_32));
    expect_illegal(
        encode_r(FUNCT7_BASE, 5'd3, 5'd1, FUNCT3_ADD_SUB, 5'd2, OPCODE_OP_32));
    expect_illegal(encode_i(12'h010, 5'd1, FUNCT3_LWU, 5'd2, OPCODE_LOAD));
    expect_illegal(encode_i(12'h018, 5'd1, FUNCT3_LD, 5'd2, OPCODE_LOAD));
    expect_illegal(encode_s(12'h020, 5'd2, 5'd1, FUNCT3_SD, OPCODE_STORE));
    expect_illegal(encode_i(12'h020, 5'd1, FUNCT3_SLL, 5'd2, OPCODE_OP_IMM));

    apply_instruction(encode_u(20'h80000, 5'd2, OPCODE_LUI));
    assert (!decoded_uop.exception_valid && decoded_uop.imm == 32'h8000_0000)
      else $fatal(1, "RV32 LUI immediate changed during RV64 decode work");
`endif

    $display("IDU directed decode test passed for XLEN=%0d", XLEN);
    $finish;
  end

endmodule : riscv32_idu_decode_tb
