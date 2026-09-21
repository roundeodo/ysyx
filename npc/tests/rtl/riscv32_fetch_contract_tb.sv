// 连接真实 IFU 与预测器，验证命中 taken 的目标查询间隔。
module riscv32_fetch_contract_tb;
  import riscv32_pkg::*;
  logic clk=0, predictor_reset_n=0, ifu_reset_n=0;
  always #5 clk=~clk;
  localparam program_counter_t BASE=32'h80000000;
  program_counter_t query_pc, response_pc;
  fetch_epoch_t query_epoch, response_epoch;
  branch_prediction_t prediction;
  logic query_valid, query_ready, response_valid, response_ready, flush;
  program_counter_t train_pc, train_target;
  logic train_valid=0;
  icache_lookup_req_t cache_request;
  icache_lookup_resp_t cache_response;
  logic cache_request_valid, cache_response_valid=0, cache_response_ready;
  fetch_entry_t fetched;
  logic fetched_valid;
  int cycle=0, requests=0, deliveries=0, previous_cycle=-1;

  riscv32_ifu #(.PC_START(BASE)) ifu (
      .prediction_enable_i(1'b1),
      .clk_i(clk), .rst_ni(ifu_reset_n), .redirect_req_i('0), .redirect_req_valid_i(1'b0),
      .next_pc_predictor_lookup_request_pc_o(query_pc),
      .next_pc_predictor_lookup_request_epoch_o(query_epoch),
      .next_pc_predictor_lookup_request_valid_o(query_valid),
      .next_pc_predictor_lookup_request_ready_i(query_ready),
      .next_pc_predictor_lookup_response_pc_i(response_pc),
      .next_pc_predictor_lookup_response_epoch_i(response_epoch),
      .next_pc_predictor_prediction_i(prediction),
      .next_pc_predictor_lookup_response_valid_i(response_valid),
      .next_pc_predictor_lookup_response_ready_o(response_ready),
      .next_pc_predictor_flush_o(flush),
      .icache_lookup_req_o(cache_request), .icache_lookup_req_valid_o(cache_request_valid),
      .icache_lookup_req_ready_i(1'b1), .icache_lookup_resp_i(cache_response),
      .icache_lookup_resp_valid_i(cache_response_valid), .icache_lookup_resp_ready_o(cache_response_ready),
      .fetch_entry_o(fetched), .fetch_entry_valid_o(fetched_valid), .fetch_entry_ready_i(1'b1)
  );
  riscv32_branch_predictor predictor (
      .clk_i(clk), .rst_ni(predictor_reset_n), .lookup_request_pc_i(query_pc),
      .lookup_request_epoch_i(query_epoch), .lookup_request_valid_i(query_valid && ifu_reset_n),
      .lookup_request_ready_o(query_ready), .lookup_response_pc_o(response_pc),
      .lookup_response_epoch_o(response_epoch), .lookup_prediction_o(prediction), .lookup_next_pc_o(),
      .lookup_response_valid_o(response_valid), .lookup_response_ready_i(response_ready),
      .resolved_control_flow_pc_i(train_pc), .resolved_control_flow_target_i(train_target),
      .resolved_control_flow_imm_i('0), .resolved_control_flow_op_i(CF_JAL),
      .resolved_control_flow_rs1_i('0), .resolved_control_flow_rd_i('0),
      .resolved_control_flow_event_i(train_valid), .resolved_control_flow_taken_i(1'b1),
      .flush_lookup_i(flush), .invalidate_i(1'b0)
  );

  always @(posedge clk) begin
    cycle++;
    cache_response_valid <= ifu_reset_n && cache_request_valid;
    if (ifu_reset_n && cache_request_valid) begin
      assert(cache_request.fetch_addr == BASE + program_counter_t'((requests%4)*4))
        else $fatal(1,"IFU sent an incorrect predicted PC");
      if(previous_cycle>=0)
        assert(cycle-previous_cycle==1) else $fatal(1,"taken target interval should be one cycle");
      previous_cycle=cycle; requests++;
      cache_response <= '{fetch_addr:cache_request.fetch_addr, fetch_data:32'h00000013,
                           frontend_tag:cache_request.frontend_tag,
                           fetch_epoch:cache_request.fetch_epoch, access_fault:1'b0};
    end
    if(fetched_valid) begin
      assert(fetched.pc == BASE + program_counter_t'((deliveries%4)*4) &&
             fetched.prediction.predicted_taken && fetched.prediction.predicted_target ==
             BASE + program_counter_t'(((deliveries+1)%4)*4))
        else $fatal(1,"IFU lost predicted identity or target");
      deliveries++;
    end
    if(deliveries==100) begin
      $display("PASS fetch taken loop: 100 deliveries, target interval 1 cycle");
      $finish;
    end
  end
  initial begin
    train_pc=BASE; train_target=BASE+4;
    repeat(3) @(negedge clk); predictor_reset_n=1;
    for(int i=0;i<4;i++) begin
      train_pc=BASE+program_counter_t'(i*4);
      train_target=BASE+program_counter_t'(((i+1)%4)*4);
      train_valid=1;
      @(negedge clk);
    end
    train_valid=0;
    repeat(3) @(negedge clk); ifu_reset_n=1;
  end
  initial begin #10000; $fatal(1,"taken-loop timeout"); end
endmodule
