module riscv32_execute_result_timing_tb;
  import riscv32_pkg::*;
  logic clk = 1'b0;
  always #5 clk = ~clk;
  logic rst_n = 1'b0;
  execute_result_t executed_result;
  execute_result_t resolved_result;
  logic executed_valid;
  logic executed_ready;
  logic resolved_valid;
  logic resolved_ready;
  logic flush;
  execute_result_t expected_payload;
  execute_result_t expected_result;
  logic expected_valid;
  logic can_accept;
  program_counter_t expected_next_pc;

  riscv32_ex_result_reg u_dut (
      .clk_i(clk), .rst_ni(rst_n),
      .executed_result_i(executed_result), .executed_result_valid_i(executed_valid),
      .executed_result_ready_o(executed_ready),
      .resolved_result_o(resolved_result), .resolved_result_valid_o(resolved_valid),
      .resolved_result_ready_i(resolved_ready), .flush_i(flush)
  );

  initial begin
    executed_result = '0; executed_valid = 0; resolved_ready = 0; flush = 0;
    expected_payload = '0; expected_valid = 0;
    repeat (2) @(negedge clk);
    rst_n = 1;
    for (int unsigned index = 0; index < 1024; index++) begin
      @(negedge clk);
      executed_result = '0;
      executed_result.uop.pc = (index % 8 == 0) ? program_counter_t'('hffff_fffc) :
                                               program_counter_t'($urandom);
      executed_result.uop.prediction.predicted_taken = 1'(index);
      executed_result.uop.prediction.predicted_target = program_counter_t'($urandom);
      executed_result.uop.fu_type = (index % 7 == 0) ? FU_INT : FU_BRANCH;
      executed_result.uop.exception_valid = (index % 11 == 0);
      case (index % 3)
        0: executed_result.next_pc = executed_result.uop.pc + program_counter_t'(4);
        1: executed_result.next_pc = executed_result.uop.prediction.predicted_target;
        2: executed_result.next_pc = program_counter_t'($urandom);
      endcase
      executed_valid = (index % 5 != 0);
      resolved_ready = (index % 4 != 0);
      flush = (index % 13 == 0);
      #1;
      can_accept = !expected_valid || resolved_ready;
      assert (executed_ready == can_accept) else $fatal(1, "EX/MEM capacity changed");
      @(posedge clk);
      if (can_accept) begin
        expected_valid = executed_valid;
        if (executed_valid) expected_payload = executed_result;
      end
      if (flush) expected_valid = 0;
      #1;
      assert (resolved_valid == expected_valid) else $fatal(1, "EX/MEM valid/flush mismatch");
      if (expected_valid) begin
        expected_next_pc = expected_payload.uop.prediction.predicted_taken ?
                           expected_payload.uop.prediction.predicted_target :
                           expected_payload.uop.pc + program_counter_t'(4);
        expected_result = expected_payload;
        expected_result.redirect_req = '0;
        expected_result.redirect_req.target_pc = expected_payload.next_pc;
        expected_result.redirect_req.source_pc = expected_payload.uop.pc;
        expected_result.redirect_req.reason = REDIRECT_BRANCH_MISPREDICT;
        expected_result.redirect_valid = expected_payload.uop.fu_type == FU_BRANCH &&
                                         !expected_payload.uop.exception_valid &&
                                         expected_payload.next_pc != expected_next_pc;
        assert (resolved_result == expected_result)
          else $fatal(1, "EX/MEM prediction/payload mismatch at case %0d", index);
      end
    end
    $display("PASS execute result: 1024 prediction, PC wrap, payload, backpressure and flush cases");
    $finish;
  end
endmodule
