// 重定向到来时，旧 lookup 仍在等待 ready；稍后握手不能覆盖恢复 PC。
module riscv32_ifu_redirect_tb;
  import riscv32_pkg::*;
  logic clk = 0;
  logic rst_n = 0;
  always #5 clk = ~clk;
  redirect_req_t redirect;
  logic redirect_valid = 0;
  icache_lookup_req_t request;
  logic request_valid;
  logic request_ready = 0;
  icache_lookup_resp_t response;
  logic response_valid = 0;
  logic response_ready;
  logic fetch_valid;
  program_counter_t predictor_request_pc, predictor_response_pc;
  fetch_epoch_t predictor_request_epoch, predictor_response_epoch;
  logic predictor_request_valid, predictor_request_ready;
  logic predictor_response_valid, predictor_response_ready, predictor_flush;
  branch_prediction_t prediction;
  riscv32_branch_predictor predictor (
      .clk_i(clk), .rst_ni(rst_n),
      .lookup_request_pc_i(predictor_request_pc),
      .lookup_request_epoch_i(predictor_request_epoch),
      .lookup_request_valid_i(predictor_request_valid),
      .lookup_request_ready_o(predictor_request_ready),
      .lookup_response_pc_o(predictor_response_pc),
      .lookup_response_epoch_o(predictor_response_epoch),
      .lookup_prediction_o(prediction), .lookup_next_pc_o(),
      .lookup_response_valid_o(predictor_response_valid),
      .lookup_response_ready_i(predictor_response_ready),
      .resolved_control_flow_pc_i('0), .resolved_control_flow_target_i('0),
      .resolved_control_flow_imm_i('0), .resolved_control_flow_op_i(CF_NONE),
      .resolved_control_flow_rs1_i('0), .resolved_control_flow_rd_i('0),
      .resolved_control_flow_event_i(1'b0), .resolved_control_flow_taken_i(1'b0),
      .flush_lookup_i(predictor_flush), .invalidate_i(1'b0)
  );
  riscv32_ifu #(.PC_START(32'h8000_0000)) dut (
      .next_pc_predictor_lookup_request_pc_o(predictor_request_pc),
      .next_pc_predictor_lookup_request_epoch_o(predictor_request_epoch),
      .next_pc_predictor_lookup_request_valid_o(predictor_request_valid),
      .next_pc_predictor_lookup_request_ready_i(predictor_request_ready),
      .next_pc_predictor_lookup_response_pc_i(predictor_response_pc),
      .next_pc_predictor_lookup_response_epoch_i(predictor_response_epoch),
      .next_pc_predictor_prediction_i(prediction),
      .next_pc_predictor_lookup_response_valid_i(predictor_response_valid),
      .next_pc_predictor_lookup_response_ready_o(predictor_response_ready),
      .next_pc_predictor_flush_o(predictor_flush),
      .clk_i(clk), .rst_ni(rst_n), .redirect_req_i(redirect),
      .redirect_req_valid_i(redirect_valid), .icache_lookup_req_o(request),
      .icache_lookup_req_valid_o(request_valid), .icache_lookup_req_ready_i(request_ready),
      .icache_lookup_resp_i(response), .icache_lookup_resp_valid_i(response_valid),
      .icache_lookup_resp_ready_o(response_ready), .fetch_entry_o(),
      .fetch_entry_valid_o(fetch_valid), .fetch_entry_ready_i(1'b1)
  );
  initial begin
    #10000;
    $fatal(1, "IFU test timed out");
  end
  initial begin
    redirect = '0;
    response = '0;
    repeat (3) @(negedge clk);
    rst_n = 1;
    while (!request_valid) @(negedge clk);
    assert (request_valid && request.fetch_addr == 32'h8000_0000)
      else $fatal(1, "missing initial lookup");
    response.fetch_addr = request.fetch_addr;
    response.frontend_tag = request.frontend_tag;
    response.fetch_epoch = request.fetch_epoch;
    redirect_valid = 1;
    redirect.target_pc = 32'h8000_1000;
    @(negedge clk);
    redirect.target_pc = 32'h8000_2000; // 再次重定向，最后一个目标必须保留。
    @(negedge clk);
    redirect_valid = 0;
    request_ready = 1;
    @(negedge clk);
    request_ready = 0;
    response_valid = 1;
    #1;
    assert (response_ready && !fetch_valid) else $fatal(1, "stale response not discarded");
    @(negedge clk);
    response_valid = 0;
    while (!request_valid) @(negedge clk);
    #1;
    assert (request_valid && request.fetch_addr == 32'h8000_2000)
      else $fatal(1, "redirect target overwritten by late lookup handshake: %h", request.fetch_addr);
    $display("PASS IFU redirect: backpressured lookup, consecutive redirects, late handshake, stale response drain");
    $finish;
  end
endmodule
