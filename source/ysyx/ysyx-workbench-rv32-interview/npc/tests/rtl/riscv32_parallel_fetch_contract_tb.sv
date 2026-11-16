// 真实预测器与IFU：随机cache延迟/反压，独立按返回指令检查PC顺序和身份。
module riscv32_parallel_fetch_contract_tb;
  import riscv32_pkg::*;
  localparam program_counter_t BASE = 32'h8000_0000;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  redirect_req_t redirect;
  logic redirect_valid, prediction_enable, fetch_ready;
  program_counter_t query_pc, prediction_pc;
  fetch_epoch_t query_epoch, prediction_epoch;
  branch_prediction_t prediction;
  logic query_valid, query_ready, prediction_valid, prediction_ready, flush;
  icache_lookup_req_t request, cache_request_q;
  icache_lookup_resp_t response;
  icache_fetch_data_t preview;
  logic request_valid, request_ready, response_valid, response_ready;
  fetch_entry_t fetched;
  logic fetched_valid;

  riscv32_ifu #(.PC_START(BASE)) dut (
      .clk_i(clk), .rst_ni(rst_n), .redirect_req_i(redirect),
      .redirect_req_valid_i(redirect_valid), .prediction_enable_i(prediction_enable),
      .early_return_present_i(1'b0), .early_return_pc_i('0),
      .next_pc_predictor_lookup_request_pc_o(query_pc),
      .next_pc_predictor_lookup_request_epoch_o(query_epoch),
      .next_pc_predictor_lookup_request_valid_o(query_valid),
      .next_pc_predictor_lookup_request_ready_i(query_ready),
      .next_pc_predictor_lookup_response_pc_i(prediction_pc),
      .next_pc_predictor_lookup_response_epoch_i(prediction_epoch),
      .next_pc_predictor_prediction_i(prediction),
      .next_pc_predictor_lookup_response_valid_i(prediction_valid),
      .next_pc_predictor_lookup_response_ready_o(prediction_ready),
      .next_pc_predictor_flush_o(flush),
      .icache_lookup_req_o(request), .icache_lookup_req_valid_o(request_valid),
      .icache_lookup_req_ready_i(request_ready), .icache_lookup_resp_i(response),
      .icache_lookup_word_i(preview), .icache_lookup_resp_valid_i(response_valid),
      .icache_lookup_resp_ready_o(response_ready), .fetch_entry_o(fetched),
      .fetch_entry_valid_o(fetched_valid), .fetch_entry_ready_i(fetch_ready)
  );
  riscv32_branch_predictor predictor (
      .clk_i(clk), .rst_ni(rst_n), .lookup_request_pc_i(query_pc),
      .lookup_request_epoch_i(query_epoch), .lookup_request_valid_i(query_valid),
      .lookup_request_ready_o(query_ready), .lookup_response_pc_o(prediction_pc),
      .lookup_response_epoch_o(prediction_epoch), .lookup_prediction_o(prediction),
      .lookup_next_pc_o(), .lookup_response_valid_o(prediction_valid),
      .lookup_response_ready_i(prediction_ready),
      .resolved_control_flow_pc_i('0), .resolved_control_flow_target_i('0),
      .resolved_control_flow_imm_i('0), .resolved_control_flow_op_i(CF_NONE),
      .resolved_control_flow_rs1_i('0), .resolved_control_flow_rd_i('0),
      .resolved_control_flow_event_i(1'b0), .resolved_control_flow_taken_i(1'b0),
      .resolved_control_flow_prediction_i('0), .early_return_present_o(), .early_return_pc_o(),
      .flush_lookup_i(flush), .invalidate_i(!prediction_enable)
  );

  // 一个cache响应上下文。delay模拟miss；tail模拟关键字返回后仍未完成的回填。
  logic cache_present_q = 0, cache_allow = 1;
  int delay_q = 0, tail_q = 0;
  assign request_ready = cache_allow && tail_q == 0 &&
      (!cache_present_q || (response_valid && response_ready));
  assign response_valid = cache_present_q && delay_q == 0;
  assign preview = cache_request_q.fetch_addr[5:0] == 6'h1c ? 32'h0100006f : 32'h00000013;
  always_comb begin
    response = '0;
    response.fetch_addr = cache_request_q.fetch_addr;
    response.frontend_tag = cache_request_q.frontend_tag;
    response.fetch_epoch = cache_request_q.fetch_epoch;
    response.access_fault = (int'(cache_request_q.frontend_tag) % 5 == 3);
    response.fetch_data = response.access_fault ? '0 : preview;
  end
  always @(posedge clk) if (rst_n) begin
    if (delay_q > 0) delay_q <= delay_q - 1;
    if (tail_q > 0) tail_q <= tail_q - 1;
    if (response_valid && response_ready) cache_present_q <= 0;
    if (request_valid && request_ready) begin
      cache_present_q <= 1;
      cache_request_q <= request;
      delay_q <= int'(request.frontend_tag) % 7;
      tail_q <= int'(request.frontend_tag) % 7 + 3;
    end
  end

  int cycle = 0, deliveries = 0, faults = 0, early = 0, stale = 0;
  int stalled_requests = 0, held_predictions = 0, recovery_with_response = 0;
  int unsigned random_state = 32'h14c75e9a;
  program_counter_t expected_pc = BASE;
  always @(posedge clk) if (rst_n) begin
    cycle++;
    if (cycle == 1)
      assert (query_valid && request_valid && query_pc == BASE && request.fetch_addr == BASE)
        else $fatal(1, "first cache request waited for a predictor response");
    if (redirect_valid) expected_pc = redirect.target_pc;
    if (fetched_valid && fetch_ready) begin
      assert (fetched.pc == expected_pc && fetched.instruction == response.fetch_data &&
              fetched.frontend_tag == cache_request_q.frontend_tag &&
              fetched.exception_valid == response.access_fault)
        else $fatal(1, "parallel fetch stream mismatch: got %h expected %h", fetched.pc, expected_pc);
      expected_pc = expected_pc +
          program_counter_t'(!response.access_fault && preview == 32'h0100006f ? 16 : 4);
      deliveries++;
      if (response.access_fault) faults++;
    end
    if (dut.early_redirect_event) early++;
    if (response_valid && response_ready && !fetched_valid) stale++;
    if (request_valid && !request_ready) stalled_requests++;
    if (prediction_valid && !prediction_ready) held_predictions++;
    if (redirect_valid && response_valid) recovery_with_response++;
  end

  initial begin
    redirect = '0;
    redirect_valid = 0;
    prediction_enable = 1;
    fetch_ready = 1;
    repeat (3) @(negedge clk);
    rst_n = 1;
    for (int index = 0; index < 16000; index++) begin
      @(negedge clk);
      random_state = (random_state << 1) ^ (random_state[31] ? 32'h80200003 : 0);
      cache_allow = random_state[0] || random_state[3];
      fetch_ready = random_state[5] || random_state[8];
      // 连续两次恢复；紧随其后十拍维护暂停，已展示旧请求仍必须排空。
      redirect_valid = index % 503 inside {123, 124};
      redirect.target_pc = BASE + program_counter_t'((index / 503 % 8) * 64);
      prediction_enable = !(index % 503 inside {[125:134]});
    end
    $display("coverage: deliveries=%0d faults=%0d early=%0d stale=%0d stalled=%0d held=%0d recovery=%0d", deliveries, faults, early, stale, stalled_requests, held_predictions, recovery_with_response);
    assert (deliveries > 1000 && faults > 40 && early > 40 && stale > 10 &&
            stalled_requests > 100 && held_predictions > 100 && recovery_with_response > 0)
      else $fatal(1, "parallel fetch stress coverage incomplete");
    $display("PASS parallel fetch: delivered=%0d faults=%0d early=%0d stale=%0d request_stall=%0d prediction_hold=%0d recovery_response=%0d",
             deliveries, faults, early, stale, stalled_requests, held_predictions, recovery_with_response);
    $finish;
  end
endmodule
