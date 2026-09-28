module riscv32_mul_pipeline_tb;
  import riscv32_pkg::*;
  logic clk = 0;
  always #5 clk = ~clk;
  logic rst_n = 0, flush = 0, valid = 0, ready = 1, issue = 1;
  fetch_entry_t fetch;
  decoded_uop_t decoded;
  execute_packet_t packet;
  execute_result_t result;
  logic packet_ready, result_valid, redirect_valid, busy;
  redirect_req_t redirect;
  execute_producer_t producer [EXECUTE_PIPE_DEPTH];
  riscv32_idu u_idu (
      .fetch_entry_i(fetch), .fetch_entry_valid_i(1'b1), .fetch_entry_ready_o(),
      .decoded_uop_o(decoded), .decoded_uop_valid_o(), .decoded_uop_ready_i(1'b1)
  );
  riscv32_exu u_exu (
      .clk_i(clk), .rst_ni(rst_n), .flush_i(flush),
      .execute_packet_i(packet), .execute_packet_valid_i(valid),
      .multiply_operand_a_i(packet.source_a_value[31:0]),
      .multiply_operand_b_i(packet.source_b_value[31:0]),
      .execute_packet_issue_allowed_i(issue), .execute_packet_ready_o(packet_ready),
      .exu_result_o(result), .exu_result_valid_o(result_valid), .exu_result_ready_i(ready),
      .muldiv_result_available_o(), .execute_forwarding_value_o(),
      .pipeline_busy_o(busy), .pipeline_producer_o(producer),
      .lsu_req_o(), .lsu_req_valid_o(), .lsu_req_ready_i(1'b1),
      .sequential_redirect_o(redirect), .sequential_redirect_valid_o(redirect_valid)
  );
  typedef struct packed {logic [31:0] pc, value; logic correction;} expected_t;
  expected_t expected_queue[$], current, retired;
  string vectors;
  integer fd, fields, operation, marker, mode, step = 0, accepted = 0, delivered = 0;
  integer canceled = 0, corrections = 0, last_accept = -1, last_delivery = -1;
  integer burst_accepts = 0, burst_deliveries = 0;
  logic [31:0] a, b, value;
  logic source_present = 0, end_of_input = 0, popped;
  logic [31:0] rng = 32'h87a03129;
  initial begin
    fetch = '0; packet = '0;
    repeat (2) @(negedge clk);
    rst_n = 1;
    if (!$value$plusargs("vectors=%s", vectors)) $fatal(1, "vectors missing");
    fd = $fopen(vectors, "r");
    if (!fd) $fatal(1, "cannot open vectors");
    while (!end_of_input || source_present || expected_queue.size() != 0 || busy) begin
      if (!source_present && !end_of_input) begin
        fields = $fscanf(fd, "%d %h %h %h %d\n", operation, a, b, value, mode);
        if (fields != 5) begin
          if (!$feof(fd)) $fatal(1, "malformed vector");
          end_of_input = 1;
        end else begin
          fetch = '0;
          fetch.pc = 32'h80000100 + 4 * accepted + 4 * canceled;
          fetch.instruction = operation == 8 ? 32'h002081b3 :
              {7'b0000001, 5'd2, 5'd1, 3'(operation), 5'd3, 7'b0110011};
          #1;
          packet = '0; packet.uop = decoded;
          packet.source_a_value = a; packet.source_b_value = b;
          packet.uop.prediction.predicted_taken = mode == 2;
          packet.uop.prediction.predicted_target = 32'h80010000;
          current.pc = fetch.pc; current.value = value; current.correction = mode == 2;
          source_present = 1;
        end
      end
      valid = source_present;
      rng = {rng[30:0], rng[31] ^ rng[21] ^ rng[1] ^ rng[0]};
      ready = mode == 0 || rng[2:0] != 0;
      issue = mode == 0 || rng[5:3] != 0;
      flush = mode != 0 && step % 251 == 250;
      if (flush) issue = 0;
      #1;
      popped = 0;
      if (valid && issue && packet_ready) begin
        expected_queue.push_back(current);
        if (mode == 0) begin
          if (last_accept >= 0 && step != last_accept + 1)
            $fatal(1, "independent multiply not accepted every cycle");
          last_accept = step;
          burst_accepts++;
        end
        accepted++;
        source_present = 0;
      end
      if (result_valid && ready) begin
        if (expected_queue.size() == 0) $fatal(1, "unmatched output");
        retired = expected_queue.pop_front();
        if (result.uop.pc != retired.pc || result.result != retired.value)
          $fatal(1, "result/identity mismatch pc=%h/%h value=%h/%h step=%0d",
                 result.uop.pc, retired.pc, result.result, retired.value, step);
        if (redirect_valid != retired.correction)
          $fatal(1, "missing or premature nonbranch correction");
        if (mode == 0 && delivered >= 2) begin
          if (last_delivery >= 0 && step != last_delivery + 1)
            $fatal(1, "independent multiply not delivered every cycle");
          last_delivery = step;
          burst_deliveries++;
        end
        delivered++;
        popped = 1;
      end
      if (flush || redirect_valid) begin
        if (redirect_valid) begin
          corrections++;
          if (!popped || redirect.target_pc != retired.pc + 4)
            $fatal(1, "incorrect sequential redirect");
        end
        canceled += expected_queue.size() + int'(source_present);
        expected_queue.delete();
        source_present = 0;
      end
      @(posedge clk); #1; @(negedge clk);
      step++;
      if (step > 1000000) $fatal(1, "pipeline timeout");
    end
    if (burst_accepts < 128 || burst_deliveries < 124 || corrections < 10 || canceled == 0)
      $fatal(1, "coverage incomplete");
    $display("PASS pipeline accepted=%0d delivered=%0d canceled=%0d corrections=%0d burst=%0d/%0d cycles=%0d",
             accepted, delivered, canceled, corrections, burst_accepts, burst_deliveries, step);
    $finish;
  end
endmodule
