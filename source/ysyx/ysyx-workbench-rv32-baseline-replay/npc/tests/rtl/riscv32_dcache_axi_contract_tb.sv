// 读写同时分配，分别推迟 AR、AW、W、R、B 和上游响应接收。
module riscv32_dcache_axi_contract_tb;
  import riscv32_pkg::*;
  import riscv32_addr_map_pkg::*;
  import riscv32_axi4_pkg::*;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  dcache_refill_req_t refill_req;
  dcache_refill_resp_t refill_resp;
  dcache_writeback_req_t writeback_req;
  dcache_writeback_resp_t writeback_resp;
  dcache_line_data_t writeback_line;
  logic refill_valid = 0, refill_ready, refill_response_valid, refill_response_ready = 0;
  logic writeback_valid = 0, writeback_ready, writeback_response_valid;
  logic writeback_response_ready = 0;
  axi4_manager_to_target_t manager;
  axi4_target_to_manager_t target;
  int cases = 0;

  riscv32_dcache_axi dut (
      .clk_i(clk),
      .rst_ni(rst_n),
      .refill_req_i(refill_req),
      .refill_req_valid_i(refill_valid),
      .refill_req_ready_o(refill_ready),
      .refill_resp_o(refill_resp),
      .refill_resp_valid_o(refill_response_valid),
      .refill_resp_ready_i(refill_response_ready),
      .writeback_req_i(writeback_req),
      .writeback_req_valid_i(writeback_valid),
      .writeback_req_ready_o(writeback_ready),
      .writeback_line_data_i(writeback_line),
      .writeback_resp_o(writeback_resp),
      .writeback_resp_valid_o(writeback_response_valid),
      .writeback_resp_ready_i(writeback_response_ready),
      .axi_manager_o(manager),
      .axi_manager_i(target)
  );

  task automatic check_channels(input int aw_delay, input int w_delay, input int ar_delay,
                                input bit bus_fault);
    int local_writes, local_reads, aw_count, ar_count, w_count, r_count, b_count;
    bit complete;
    local_writes                 = 0;
    local_reads                  = 0;
    aw_count                     = 0;
    ar_count                     = 0;
    w_count                      = 0;
    r_count                      = 0;
    b_count                      = 0;
    complete                     = 0;
    refill_req                   = '0;
    refill_req.line_base_addr    = phys_addr_t'(32'h80000200);
    refill_req.transaction_id    = mem_txn_id_t'(3);
    writeback_req                = '0;
    writeback_req.line_base_addr = phys_addr_t'(32'h80000400);
    writeback_req.transaction_id = mem_txn_id_t'(5);
    for (int word_index = 0; word_index < DCACHE_WORDS_PER_LINE; word_index++)
      writeback_line[word_index*CORE_DATA_WIDTH+:CORE_DATA_WIDTH] = core_data_t'(32'h12340000+word_index);

    for (int cycle = 0; cycle < 160 && !complete; cycle++) begin
      @(negedge clk);
      refill_valid = local_reads == 0;
      writeback_valid = local_writes == 0;
      refill_response_ready = cycle >= 5 && cycle % 3 != 1;
      writeback_response_ready = cycle >= 20;
      target = '0;
      target.ar_ready = cycle >= ar_delay && ar_count == 0;
      target.aw_ready = cycle >= aw_delay && aw_count == 0;
      target.w_ready = cycle >= w_delay && cycle % 3 != 2 && w_count < DCACHE_WORDS_PER_LINE;
      target.r_valid = ar_count == 1 && r_count < DCACHE_WORDS_PER_LINE;
      target.r.data = MEM_AXI_DATA_WIDTH'(32'h56780000 + r_count);
      target.r.id = MEM_AXI_ID_WIDTH'(1);
      target.r.last = r_count == DCACHE_WORDS_PER_LINE - 1;
      target.r.resp = bus_fault && r_count == 0 ? AXI4_RESP_SLVERR : AXI4_RESP_OKAY;
      target.b_valid = aw_count == 1 && w_count == DCACHE_WORDS_PER_LINE && b_count == 0;
      target.b.id = MEM_AXI_ID_WIDTH'(2);
      target.b.resp = bus_fault ? AXI4_RESP_SLVERR : AXI4_RESP_OKAY;
      @(posedge clk);
      if (writeback_valid && writeback_ready) local_writes++;
      if (refill_valid && refill_ready) local_reads++;
      if (manager.aw_valid) begin
        assert(manager.aw.addr == writeback_req.line_base_addr &&
               manager.aw.len == DCACHE_WORDS_PER_LINE-1)
        else $fatal(1, "AW payload changed or incorrect");
        if (target.aw_ready) aw_count++;
      end
      if (manager.w_valid) begin
        assert(manager.w.data == MEM_AXI_DATA_WIDTH'(32'h12340000+w_count) &&
               manager.w.strb == '1 && manager.w.last == (w_count == DCACHE_WORDS_PER_LINE-1))
        else $fatal(1, "W word, strobe or last mismatch");
        if (target.w_ready) w_count++;
      end
      if (manager.ar_valid) begin
        assert(manager.ar.addr == refill_req.line_base_addr &&
               manager.ar.len == DCACHE_WORDS_PER_LINE-1)
        else $fatal(1, "AR payload changed or incorrect");
        if (target.ar_ready) ar_count++;
      end
      if (refill_response_valid && refill_response_ready) begin
        assert(refill_resp.transaction_id == mem_txn_id_t'(3) &&
               refill_resp.word_index == dcache_word_index_t'(r_count) &&
               refill_resp.word_data == core_data_t'(32'h56780000+r_count) &&
               refill_resp.access_fault == (bus_fault && r_count == 0) &&
               refill_resp.last_word == (r_count == DCACHE_WORDS_PER_LINE-1))
        else $fatal(1, "R forwarding mismatch");
        r_count++;
      end
      if (writeback_response_valid && writeback_response_ready) begin
        assert(writeback_resp.access_fault == bus_fault &&
               writeback_resp.transaction_id == mem_txn_id_t'(5))
        else $fatal(1, "B forwarding mismatch");
        b_count++;
      end
      complete = b_count == 1 && r_count == DCACHE_WORDS_PER_LINE;
    end
    assert(complete && aw_count == 1 && ar_count == 1 &&
           local_reads == 1 && local_writes == 1 && w_count == DCACHE_WORDS_PER_LINE)
    else $fatal(1, "Channel transaction lost, repeated or timed out");
    @(negedge clk);
    refill_valid    = 0;
    writeback_valid = 0;
    target          = '0;
    repeat (2) @(negedge clk);
    assert (refill_ready && writeback_ready)
    else $fatal(1, "Adapter failed to return idle");
    cases++;
  endtask

  initial begin
    target         = '0;
    refill_req     = '0;
    writeback_req  = '0;
    writeback_line = '0;
    repeat (3) @(negedge clk);
    rst_n = 1;
    for (int fault = 0; fault < 2; fault++) begin
      check_channels(0, 0, 0, 1'(fault));
      check_channels(12, 0, 2, 1'(fault));  // W 可在 AW 前完成。
      check_channels(0, 12, 4, 1'(fault));
      check_channels(4, 7, 12, 1'(fault));
    end
    $display("PASS D-cache AXI contract: %0d cases, independent channels and response stalls",
             cases);
    $finish;
  end
  initial begin
    #100000;
    $fatal(1, "D-cache AXI contract timeout");
  end
endmodule
