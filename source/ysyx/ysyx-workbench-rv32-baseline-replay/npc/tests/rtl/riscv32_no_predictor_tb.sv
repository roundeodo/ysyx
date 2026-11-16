// 顺序取指参考：随机反压、flush、复位及训练干扰都不得改变PC/epoch配对。
module riscv32_no_predictor_tb;
  import riscv32_pkg::*;
  logic clk = 0;
  always #5 clk = ~clk;
  logic rst_n = 0, request_valid = 0, response_ready = 0, flush = 0;
  logic request_ready, response_valid;
  program_counter_t pc = 0, response_pc, next_pc;
  fetch_epoch_t epoch = 0, response_epoch;
  branch_prediction_t prediction;

  riscv32_branch_predictor #(.ENABLED(1'b0)) dut (
      .clk_i(clk), .rst_ni(rst_n),
      .lookup_request_pc_i(pc), .lookup_request_epoch_i(epoch),
      .lookup_request_valid_i(request_valid), .lookup_request_ready_o(request_ready),
      .lookup_response_pc_o(response_pc), .lookup_response_epoch_o(response_epoch),
      .lookup_prediction_o(prediction), .lookup_next_pc_o(next_pc),
      .lookup_response_valid_o(response_valid), .lookup_response_ready_i(response_ready),
      .resolved_control_flow_pc_i(pc), .resolved_control_flow_target_i(32'h80001000),
      .resolved_control_flow_imm_i(32'd16), .resolved_control_flow_op_i(CF_JAL),
      .resolved_control_flow_rs1_i(arch_reg_idx_t'(1)),
      .resolved_control_flow_rd_i(arch_reg_idx_t'(1)),
      .resolved_control_flow_event_i(1'b1), .resolved_control_flow_taken_i(1'b1),
      .flush_lookup_i(flush), .invalidate_i(flush)
  );

  logic expected_present = 0;
  program_counter_t expected_pc;
  fetch_epoch_t expected_epoch;
  logic [31:0] random_state = 32'h13c68ea7;
  int requests = 0, stalled = 0, flushes = 0;

  task automatic check_response;
    assert (response_valid == expected_present) else $fatal(1, "response occupancy");
    assert (request_ready == ((!expected_present || response_ready) && !flush))
      else $fatal(1, "request capacity");
    if (expected_present) begin
      assert (response_pc == expected_pc && response_epoch == expected_epoch)
        else $fatal(1, "PC/epoch identity");
      assert (prediction == '0 && next_pc == expected_pc + 32'd4)
        else $fatal(1, "prediction must stay sequential despite training");
    end
  endtask

  initial begin
    repeat (3) @(negedge clk);
    rst_n = 1;
    for (int cycle = 0; cycle < 12000; cycle++) begin
      if (request_ready || !request_valid || flush) begin
        pc = 32'h80000000 + {random_state[15:0], 2'b00};
        epoch = fetch_epoch_t'(random_state[19:18]);
        request_valid = random_state[0] || random_state[1];
      end
      random_state = {random_state[30:0], random_state[31] ^ random_state[21] ^
                                            random_state[1] ^ random_state[0]};
      response_ready = random_state[3] || random_state[4];
      flush = cycle % 71 == 70;
      #1;
      check_response();
      if (expected_present && !response_ready) stalled++;
      if (request_valid && request_ready) begin
        expected_present = 1;
        expected_pc = pc;
        expected_epoch = epoch;
        requests++;
      end else if (response_ready) begin
        expected_present = 0;
      end
      if (flush) begin
        expected_present = 0;
        flushes++;
      end
      @(posedge clk);
      #1;
      check_response();
      @(negedge clk);
      if (cycle == 4000 || cycle == 8000) begin
        rst_n = 0;
        expected_present = 0;
        repeat (2) @(negedge clk);
        rst_n = 1;
      end
    end
    assert (requests > 1000 && stalled > 1000 && flushes > 100);
    $display("PASS no predictor: requests=%0d stalls=%0d flushes=%0d", requests, stalled, flushes);
    $finish;
  end
endmodule
