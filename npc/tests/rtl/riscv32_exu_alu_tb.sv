module riscv32_exu_alu_tb;
  import riscv32_pkg::*;

  execute_packet_t execute_packet;
  logic            execute_packet_valid;
  logic            execute_packet_ready;
  execute_result_t exu_result;
  logic            exu_result_valid;
  lsu_req_t        lsu_req;
  logic            lsu_req_valid;

  riscv32_exu u_exu (
      .execute_packet_i(execute_packet),
      .execute_packet_valid_i(execute_packet_valid),
      .execute_packet_issue_allowed_i(1'b1),
      .execute_packet_ready_o(execute_packet_ready),
      .exu_result_o(exu_result),
      .exu_result_valid_o(exu_result_valid),
      .exu_result_ready_i(1'b1),
      .lsu_req_o(lsu_req),
      .lsu_req_valid_o(lsu_req_valid),
      .lsu_req_ready_i(1'b1)
  );

  task automatic expect_register_operation(input alu_op_e operation, input xlen_data_t operand_a,
                                           input xlen_data_t operand_b,
                                           input xlen_data_t expected_result);
    execute_packet                            = '0;
    execute_packet.uop.fu_type                = FU_INT;
    execute_packet.uop.int_ctrl.op            = operation;
    execute_packet.uop.int_ctrl.operand_a_sel = OPA_RS1;
    execute_packet.uop.int_ctrl.operand_b_sel = OPB_RS2;
    execute_packet.source_a_value             = operand_a;
    execute_packet.source_b_value             = operand_b;
    execute_packet_valid                      = 1'b1;
    #1;

    assert (execute_packet_ready && exu_result_valid && !lsu_req_valid)
    else $fatal(1, "EXU handshake or destination mismatch for ALU operation %0d", operation);
    assert (exu_result.result == expected_result)
    else
      $fatal(
          1,
          "EXU result mismatch: XLEN=%0d op=%0d a=%h b=%h expected=%h actual=%h",
          XLEN,
          operation,
          operand_a,
          operand_b,
          expected_result,
          exu_result.result
      );
  endtask

  task automatic expect_immediate_operation(input alu_op_e operation, input xlen_data_t operand_a,
                                            input xlen_data_t immediate,
                                            input xlen_data_t expected_result);
    execute_packet                            = '0;
    execute_packet.uop.fu_type                = FU_INT;
    execute_packet.uop.int_ctrl.op            = operation;
    execute_packet.uop.int_ctrl.operand_a_sel = OPA_RS1;
    execute_packet.uop.int_ctrl.operand_b_sel = OPB_IMM;
    execute_packet.uop.imm                    = immediate;
    execute_packet.source_a_value             = operand_a;
    execute_packet.source_b_value             = immediate;
    execute_packet_valid                      = 1'b1;
    #1;

    assert (execute_packet_ready && exu_result_valid && !lsu_req_valid)
    else $fatal(1, "EXU immediate-operation handshake failed for ALU operation %0d", operation);
    assert (exu_result.result == expected_result)
    else
      $fatal(
          1,
          "EXU immediate result mismatch: XLEN=%0d op=%0d a=%h imm=%h expected=%h actual=%h",
          XLEN,
          operation,
          operand_a,
          immediate,
          expected_result,
          exu_result.result
      );
  endtask

  task automatic expect_misaligned_control_flow(
      input control_flow_op_e operation, input program_counter_t instruction_pc,
      input xlen_data_t rs1_value, input xlen_data_t immediate, input xlen_data_t expected_target);
    execute_packet                    = '0;
    execute_packet.uop.fu_type        = FU_BRANCH;
    execute_packet.uop.branch_ctrl.op = operation;
    execute_packet.uop.pc             = instruction_pc;
    execute_packet.uop.imm            = immediate;
    execute_packet.uop.writes_rd      = 1'b1;
    execute_packet.source_a_value     = rs1_value;
    execute_packet_valid              = 1'b1;
    #1;

    assert (execute_packet_ready && exu_result_valid && !lsu_req_valid)
    else $fatal(1, "EXU handshake failed for misaligned control-flow operation %0d", operation);
    assert (exu_result.uop.exception_valid &&
            (exu_result.uop.exception_cause == EXC_INSTR_ADDR_MISALIGNED))
    else $fatal(1, "Misaligned control-flow target did not raise instruction-address exception");
    assert (exu_result.uop.exception_tval == expected_target)
    else
      $fatal(
          1,
          "Misaligned target mismatch: expected=%h actual=%h",
          expected_target,
          exu_result.uop.exception_tval
      );
    assert (!exu_result.redirect_valid && !exu_result.uop.writes_rd)
    else
      $fatal(1, "Faulting control-flow instruction redirected or wrote its destination register");
  endtask

  initial begin
    execute_packet       = '0;
    execute_packet_valid = 1'b0;

    // 两种配置都验证原有XLEN数据通路，防止加入*W通路后改变RV32行为。
    expect_register_operation(ALU_ADD, xlen_data_t'('1), xlen_data_t'(1), xlen_data_t'('0));
    expect_register_operation(ALU_SUB, xlen_data_t'(0), xlen_data_t'(1), xlen_data_t'('1));
    expect_register_operation(ALU_SLL, xlen_data_t'(1), xlen_data_t'(31),
                              xlen_data_t'(32'h8000_0000));
    expect_register_operation(ALU_SLT, xlen_data_t'('1), xlen_data_t'(0), xlen_data_t'(1));
    // 未实现C扩展时IALIGN=32。异常指令既不能重定向前端，也不能提交链接寄存器。
    expect_misaligned_control_flow(CF_JAL, program_counter_t'(32'h8000_0000), '0, xlen_data_t'(2),
                                   xlen_data_t'(32'h8000_0002));
    // JALR先清除bit 0；清除后bit 1仍为1时，目标依然违反IALIGN=32。
    expect_misaligned_control_flow(CF_JALR, program_counter_t'(32'h8000_0000),
                                   xlen_data_t'(32'h8000_0003), '0, xlen_data_t'(32'h8000_0002));

`ifdef YSYX_RV64_SEQUENTIAL
    // ADDIW/ADDW共享ALU_ADDW语义：先在低32位回绕，再按word_result[31]符号扩展。
    expect_immediate_operation(ALU_ADDW, 64'h0000_0000_7fff_ffff, 64'd1, 64'hffff_ffff_8000_0000);
    expect_register_operation(ALU_ADDW, 64'hffff_ffff_ffff_ffff, 64'd1, 64'd0);
    expect_register_operation(ALU_SUBW, 64'd0, 64'd1, 64'hffff_ffff_ffff_ffff);

    // *W只使用5位移位量。31覆盖符号位，32回绕为0，63回绕为31。
    expect_register_operation(ALU_SLLW, 64'd1, 64'd31, 64'hffff_ffff_8000_0000);
    expect_register_operation(ALU_SLLW, 64'hffff_ffff_0000_0001, 64'd32, 64'd1);
    expect_register_operation(ALU_SRLW, 64'hffff_ffff_8000_0000, 64'd31, 64'd1);
    expect_register_operation(ALU_SRLW, 64'hffff_ffff_8000_0000, 64'd63, 64'd1);
    expect_register_operation(ALU_SRAW, 64'h0000_0000_8000_0000, 64'd31, 64'hffff_ffff_ffff_ffff);
    expect_register_operation(ALU_SRAW, 64'h0000_0000_8000_0000, 64'd32, 64'hffff_ffff_8000_0000);

    // 普通RV64移位仍使用6位移位量，不得被*W的5位规则污染。
    expect_register_operation(ALU_SLL, 64'd1, 64'd32, 64'h0000_0001_0000_0000);
    expect_register_operation(ALU_SRL, 64'h8000_0000_0000_0000, 64'd63, 64'd1);
`endif

    $display("EXU directed ALU test passed for XLEN=%0d", XLEN);
    $finish;
  end

endmodule : riscv32_exu_alu_tb
