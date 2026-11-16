// 通过真实 EXU 结果核对分支、SLT/SLTU，与分组比较电路的写法独立。
module riscv32_branch_compare_tb;
  import riscv32_pkg::*;
  execute_packet_t packet;
  execute_result_t result;
  lsu_req_t lsu_request;
  redirect_req_t redirect;
  logic packet_ready, result_valid, lsu_valid, redirect_valid;
  int checks = 0;
  riscv32_exu dut (
      .execute_packet_i(packet), .execute_packet_valid_i(1'b1),
      .execute_packet_issue_allowed_i(1'b1), .execute_packet_ready_o(packet_ready),
      .exu_result_o(result), .exu_result_valid_o(result_valid), .exu_result_ready_i(1'b1),
      .lsu_req_o(lsu_request), .lsu_req_valid_o(lsu_valid), .lsu_req_ready_i(1'b1),
      .sequential_redirect_o(redirect), .sequential_redirect_valid_o(redirect_valid)
  );

  task automatic check_pair(input xlen_data_t left_value, right_value);
    logic expected;
    branch_cond_e conditions[6];
    conditions = '{BR_BEQ, BR_BNE, BR_BLT, BR_BGE, BR_BLTU, BR_BGEU};
    packet = '0;
    packet.source_a_value = left_value;
    packet.source_b_value = right_value;
    packet.uop.fu_type = FU_BRANCH;
    packet.uop.branch_ctrl.op = CF_BRANCH;
    packet.uop.pc = program_counter_t'(32'h80001000);
    packet.uop.imm = 8;
    for (int index = 0; index < 6; index++) begin
      packet.uop.branch_ctrl.condition = conditions[index];
      case (conditions[index])
        BR_BEQ:  expected = left_value == right_value;
        BR_BNE:  expected = left_value != right_value;
        BR_BLT:  expected = $signed(left_value) < $signed(right_value);
        BR_BGE:  expected = $signed(left_value) >= $signed(right_value);
        BR_BLTU: expected = left_value < right_value;
        BR_BGEU: expected = left_value >= right_value;
        default: $fatal(1, "invalid test condition");
      endcase
      #1;
      if (!packet_ready || !result_valid || lsu_valid || result.uop.exception_valid ||
          result.branch_taken != expected ||
          result.next_pc != packet.uop.pc + (expected ? 8 : 4))
        $fatal(1, "branch condition=%0d left=%h right=%h", conditions[index], left_value, right_value);
      if (!riscv_config_pkg::EXECUTE_RESULT_REGISTERED && result.redirect_valid != expected)
        $fatal(1, "branch comparison and EX prediction correction disagree");
      checks++;
    end
    packet.uop.fu_type = FU_INT;
    packet.uop.branch_ctrl = '0;
    packet.uop.int_ctrl.op = ALU_SLT;
    #1;
    if (result.result != xlen_data_t'($signed(left_value) < $signed(right_value)))
      $fatal(1, "SLT mismatch %h %h", left_value, right_value);
    checks++;
    packet.uop.int_ctrl.op = ALU_SLTU;
    #1;
    if (result.result != xlen_data_t'(left_value < right_value))
      $fatal(1, "SLTU mismatch %h %h", left_value, right_value);
    checks++;
  endtask

  initial begin
    packet = '0;
    check_pair('0, '0);
    check_pair('1, '1);
    check_pair('0, '1);
    check_pair('1, '0);
    for (int bit_index = 0; bit_index < XLEN; bit_index++) begin
      check_pair(xlen_data_t'(1) << bit_index, (xlen_data_t'(1) << bit_index) - 1'b1);
      check_pair((xlen_data_t'(1) << bit_index) - 1'b1, xlen_data_t'(1) << bit_index);
      check_pair('1, ~(xlen_data_t'(1) << bit_index));
    end
    for (int index = 0; index < 10000; index++)
      check_pair(xlen_data_t'({$urandom, $urandom}), xlen_data_t'({$urandom, $urandom}));
    $display("PASS branch/SLT compare: XLEN=%0d, %0d independent checks", XLEN, checks);
    $finish;
  end
endmodule
