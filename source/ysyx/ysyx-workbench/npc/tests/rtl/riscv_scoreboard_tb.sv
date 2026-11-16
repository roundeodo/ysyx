module riscv_scoreboard_tb;
  import riscv_pkg::*;
  localparam int unsigned ENTRY_COUNT = riscv_config_pkg::SCOREBOARD_ENTRY_COUNT;
  logic clk = 0;
  logic rst_n = 0;
  logic flush = 0;
  execute_result_t allocate_result;
  logic allocate_valid, allocate_completed, allocate_ready;
  scoreboard_index_t allocate_index, last_allocate_index;
  decoded_uop_t query_uop;
  writeback_result_t lsu_result, commit_result;
  arithmetic_result_t multiply_result, divide_result;
  logic lsu_valid, multiply_valid, divide_valid;
  logic rs1_pending, rs1_ready, rs2_pending, rs2_ready;
  xlen_data_t rs1_value, rs2_value;
  logic serializing_present, empty, memory_issue_allowed;
  logic commit_valid, commit_ready;
  int checks = 0;

  riscv_scoreboard dut (
      .clk_i(clk), .rst_ni(rst_n), .flush_i(flush),
      .allocate_result_i(allocate_result), .allocate_completed_i(allocate_completed),
      .allocate_valid_i(allocate_valid), .allocate_ready_o(allocate_ready),
      .allocate_index_o(allocate_index),
      .lsu_result_i(lsu_result), .lsu_result_valid_i(lsu_valid),
      .multiply_result_i(multiply_result), .multiply_result_valid_i(multiply_valid),
      .divide_result_i(divide_result), .divide_result_valid_i(divide_valid),
      .query_uop_i(query_uop), .rs1_pending_o(rs1_pending), .rs1_ready_o(rs1_ready),
      .rs1_value_o(rs1_value), .rs2_pending_o(rs2_pending), .rs2_ready_o(rs2_ready),
      .rs2_value_o(rs2_value), .serializing_present_o(serializing_present),
      .empty_o(empty), .memory_issue_allowed_o(memory_issue_allowed),
      .commit_result_o(commit_result), .commit_result_valid_o(commit_valid),
      .commit_result_ready_i(commit_ready)
  );

  task automatic tick;
    #2; clk = 1; #2; clk = 0; #2;
  endtask
  task automatic check(input logic condition, input string message);
    checks++;
    assert (condition) else $fatal(1, "%s", message);
  endtask
  task automatic clear_queue;
    allocate_valid = 0;
    lsu_valid = 0;
    multiply_valid = 0;
    divide_valid = 0;
    flush = 1;
    tick();
    flush = 0;
    #1;
    check(empty && allocate_ready && !commit_valid, "Flush retained live entries");
  endtask
  task automatic allocate(input int sequence_number, input int rd,
                          input fu_type_e fu_type = FU_MULDIV,
                          input xlen_data_t result_value = 0,
                          input mem_cmd_e memory_cmd = MEM_CMD_NONE,
                          input logic exception_valid = 0,
                          input xlen_data_t exception_tval = 0);
    allocate_result = '0;
    allocate_result.uop.pc = 64'h80000000 + 64'(4 * sequence_number);
    allocate_result.uop.instruction = instruction_t'(sequence_number);
    allocate_result.uop.rd = arch_reg_idx_t'(rd);
    allocate_result.uop.writes_rd = rd != 0;
    allocate_result.uop.fu_type = fu_type;
    allocate_result.uop.mem_ctrl.cmd = memory_cmd;
    allocate_result.uop.exception_valid = exception_valid;
    allocate_result.uop.exception_cause = EXC_ILLEGAL_INSTRUCTION;
    allocate_result.uop.exception_tval = exception_tval;
    allocate_result.uop.serializing = fu_type == FU_CSR;
    allocate_result.uop.csr_ctrl.write_enable = fu_type == FU_CSR;
    allocate_result.uop.csr_ctrl.addr = 12'h340;
    allocate_result.csr_wdata = 64'hdeadbeef01234567;
    allocate_result.result = result_value;
    allocate_result.next_pc = allocate_result.uop.pc + 4;
    allocate_completed = fu_type != FU_LSU && (fu_type != FU_MULDIV || exception_valid);
    allocate_valid = 1;
    last_allocate_index = allocate_index;
    #1;
    check(allocate_ready, "Allocation unexpectedly blocked");
    tick();
    allocate_valid = 0;
    allocate_completed = 0;
  endtask

  initial begin
    allocate_result = '0;
    query_uop = '0;
    lsu_result = '0;
    multiply_result = '0;
    divide_result = '0;
    allocate_valid = 0;
    allocate_completed = 0;
    lsu_valid = 0;
    multiply_valid = 0;
    divide_valid = 0;
    commit_ready = 0;
    check(ENTRY_COUNT >= 4, "This test requires at least four slots");
    tick(); rst_n = 1; tick();

    for (int i = 0; i < ENTRY_COUNT; i++)
      allocate(i, i + 1, i == 0 ? FU_LSU : FU_MULDIV, 0,
               i == 0 ? MEM_CMD_LOAD : MEM_CMD_NONE);
    #1;
    check(!allocate_ready && !empty && !commit_valid, "Full/incomplete state wrong");
    query_uop.uses_rs1 = 1;
    query_uop.rs1 = arch_reg_idx_t'(ENTRY_COUNT);
    #1;
    check(rs1_pending && !rs1_ready, "Unfinished latest source appeared ready");
    multiply_result.scoreboard_index = scoreboard_index_t'(ENTRY_COUNT - 1);
    multiply_result.result = 107;
    multiply_valid = 1;
    #1;
    check(rs1_ready && rs1_value == 107, "FU completion did not forward in its return cycle");
    tick(); multiply_valid = 0; #1;
    check(rs1_ready && rs1_value == 107 && !commit_valid, "Saved result lost or retired early");
    clear_queue();

    // 三个异步端口同拍完成；分配与普通结果共用一个写入口。
    for (int i = 0; i < ENTRY_COUNT; i++)
      allocate(i, i + 1, i == 0 ? FU_LSU : FU_MULDIV, 0,
               i == 0 ? MEM_CMD_LOAD : MEM_CMD_NONE);
    lsu_result.scoreboard_index = 0;
    lsu_result.result = 100;
    lsu_result.memory_addr = 64'h80001000;
    lsu_valid = 1;
    multiply_result.scoreboard_index = 1;
    multiply_result.result = 101;
    multiply_valid = 1;
    divide_result.scoreboard_index = 2;
    divide_result.result = 102;
    divide_valid = 1;
    tick(); lsu_valid = 0; multiply_valid = 0; divide_valid = 0;
    for (int i = 3; i < ENTRY_COUNT; i++) begin
      multiply_result.scoreboard_index = scoreboard_index_t'(i);
      multiply_result.result = 64'(100 + i);
      multiply_valid = 1;
      tick(); multiply_valid = 0;
    end
    repeat (4) begin
      #1;
      check(commit_valid && commit_result.uop.pc == 64'h80000000 &&
            commit_result.result == 100 && commit_result.memory_addr == 64'h80001000,
            "Oldest result changed under retirement backpressure");
      tick();
    end
    commit_ready = 1;
    allocate(ENTRY_COUNT, 9, FU_INT, 200);
    for (int i = 1; i < ENTRY_COUNT; i++) begin
      #1;
      check(commit_valid && commit_result.uop.pc == 64'h80000000 + 64'(4 * i) &&
            commit_result.result == 64'(100 + i), "Full turnover corrupted an older instruction");
      tick();
    end
    #1;
    check(commit_valid && commit_result.result == 200 &&
          commit_result.uop.pc == 64'h80000000 + 64'(4 * ENTRY_COUNT),
          "Ordinary allocation waited for a redundant return or inherited old slot data");
    tick(); #1; check(empty, "Turnover did not drain");

    for (int i = 0; i < 64; i++) begin
      allocate(100 + i, 3);
      multiply_result.scoreboard_index = last_allocate_index;
      multiply_result.result = 64'h89abcdef00000000 + 64'(i);
      multiply_valid = 1;
      tick(); multiply_valid = 0; #1;
      check(commit_valid && commit_result.uop.pc == 64'h80000000 + 64'(4 * (100 + i)) &&
            commit_result.result == 64'h89abcdef00000000 + 64'(i), "Wraparound lost identity/value");
      tick();
    end
    commit_ready = 0;
    allocate(200, 0, FU_INT, 42);
    query_uop.rs1 = 0; #1;
    check(!rs1_pending && rs1_ready, "x0 created a dependency");
    check(commit_valid && commit_result.result == 42, "Single-cycle operation added a completion bubble");
    clear_queue();

    // 最近生产者可以尚未完成；较老同名返回不得重新取得前递资格。
    query_uop.rs1 = 9;
    for (int round_index = 0; round_index < 32; round_index++) begin
      scoreboard_index_t oldest_index, newest_index;
      commit_ready = 0;
      allocate(300 + round_index * 3, 9);
      oldest_index = last_allocate_index;
      allocate(301 + round_index * 3, 9, FU_INT, 201);
      #1; check(rs1_ready && rs1_value == 201, "Ordinary result did not forward after allocation");
      allocate(302 + round_index * 3, 9);
      newest_index = last_allocate_index;
      #1; check(rs1_pending && !rs1_ready, "Pending latest writer fell back to an older result");
      divide_result.scoreboard_index = oldest_index;
      divide_result.result = 200;
      divide_valid = 1;
      #1; check(!rs1_ready, "Late older completion reclaimed forwarding ownership");
      tick(); divide_valid = 0;
      multiply_result.scoreboard_index = newest_index;
      multiply_result.result = 202;
      multiply_valid = 1;
      #1; check(rs1_ready && rs1_value == 202, "Latest completion failed to forward");
      tick(); multiply_valid = 0; commit_ready = 1;
      for (int i = 0; i < 3; i++) begin
        #1;
        check(commit_valid && commit_result.result == 64'(200 + i), "Same-rd results retired out of order");
        check(rs1_ready && rs1_value == 202, "Older retirement disturbed latest source");
        tick();
      end
      #1; check(empty && !rs1_pending, "Retired producer remained pending");
    end
    clear_queue(); commit_ready = 0;

    allocate(500, 1);
    for (int i = 1; i <= 3; i++) begin
      allocate(500 + i, i + 1, FU_LSU, 0, i == 2 ? MEM_CMD_STORE : MEM_CMD_LOAD);
      #1; check(memory_issue_allowed, "Retirement metadata stalled the LSU interface");
      lsu_result = '0;
      lsu_result.scoreboard_index = last_allocate_index;
      lsu_result.result = 64'hbeef + 64'(i);
      lsu_result.memory_addr = 64'h0f000000 + 64'(i * 8);
      lsu_result.memory_wdata = 64'h12340000 + 64'(i);
      lsu_result.memory_wmask = core_byte_strobe_t'(i);
      lsu_valid = 1;
      tick(); lsu_valid = 0;
      #1; check(!commit_valid && memory_issue_allowed, "Younger memory retired before DIV or blocked subsequent memory");
    end
    divide_result.scoreboard_index = 0;
    divide_result.result = 99;
    divide_valid = 1;
    tick(); divide_valid = 0; commit_ready = 1;
    #1; check(commit_valid && commit_result.result == 99, "DIV lost retirement priority");
    tick();
    for (int i = 1; i <= 3; i++) begin
      #1;
      check(commit_valid && commit_result.result == 64'hbeef + 64'(i) &&
            commit_result.memory_addr == 64'h0f000000 + 64'(i * 8) &&
            commit_result.memory_wdata == 64'h12340000 + 64'(i) &&
            commit_result.memory_wmask == core_byte_strobe_t'(i), "A younger memory completion overwrote retirement metadata");
      tick();
    end
    clear_queue(); commit_ready = 0;

    query_uop.rs1 = 5;
    allocate(600, 5, FU_INT, 123, MEM_CMD_NONE, 1, 64'hfedcba9876543210);
    #1;
    check(commit_valid && commit_result.uop.exception_valid && commit_result.result == 0 &&
          commit_result.uop.exception_tval == 64'hfedcba9876543210 &&
          !rs1_ready && !memory_issue_allowed, "Immediate exception leaked a value or lost tval");
    repeat (3) tick();
    clear_queue();
    allocate(601, 1);
    allocate(602, 5, FU_LSU, 0, MEM_CMD_LOAD);
    lsu_result = '0;
    lsu_result.scoreboard_index = last_allocate_index;
    lsu_result.uop.exception_valid = 1;
    lsu_result.uop.exception_cause = EXC_LOAD_ACCESS_FAULT;
    lsu_result.uop.exception_tval = 64'hfedcba980f000008;
    lsu_result.result = 64'h12345678;
    lsu_valid = 1;
    #1; check(!rs1_ready, "Faulting load forwarded a value");
    tick(); lsu_valid = 0;
    #1; check(!commit_valid && !memory_issue_allowed && !rs1_ready, "Younger load fault lost precise order");
    divide_result.scoreboard_index = 0;
    divide_result.result = 456;
    divide_valid = 1;
    tick(); divide_valid = 0; commit_ready = 1;
    #1; check(commit_valid && commit_result.result == 456, "Older DIV lost its result before trap");
    tick(); commit_ready = 0; #1;
    check(commit_valid && commit_result.uop.exception_valid && commit_result.result == 0 &&
          commit_result.uop.exception_cause == EXC_LOAD_ACCESS_FAULT &&
          commit_result.uop.exception_tval == 64'hfedcba980f000008,
          "Shared LSU fault payload lost cause/tval");
    clear_queue();
    allocate(603, 5, FU_INT, 64'h89abcdef01234567);
    #1;
    check(commit_valid && !commit_result.uop.exception_valid && commit_result.uop.exception_tval == 0 &&
          commit_result.result == 64'h89abcdef01234567 && rs1_ready &&
          rs1_value == 64'h89abcdef01234567, "Reused slot retained a previous trap payload");
    clear_queue();
    allocate(604, 5, FU_CSR, 321);
    #1;
    check(commit_valid && serializing_present && !memory_issue_allowed &&
          commit_result.uop.csr_ctrl.addr == 12'h340 && commit_result.result == 321 &&
          commit_result.csr_wdata == 64'hdeadbeef01234567, "Shared serialized CSR context lost data");
    commit_ready = 1; tick(); #1;
    check(empty && !serializing_present && memory_issue_allowed, "Retired CSR kept the backend serialized");
    $display("PASS scoreboard: %0d checks, %0d entries, immediate ordinary results, three return ports, latest writer, memory overlap, precise traps", checks, ENTRY_COUNT);
    $finish;
  end
endmodule
