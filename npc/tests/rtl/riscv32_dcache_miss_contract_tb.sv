// Miss engine 的完成边界：R/B 任意先后、错误、反压和 clean。
module riscv32_dcache_miss_contract_tb;
  import riscv32_pkg::*;
  import riscv32_addr_map_pkg::*;
  logic clk=0, rst_n=0;
  always #5 clk=~clk;
  dcache_miss_req_t request;
  logic request_valid=0, request_ready;
  data_memory_resp_t response;
  logic response_valid, response_ready=0;
  logic clean_valid=0, clean_ready, clean_done, clean_fault, busy;
  logic victim_read;
  dcache_set_index_t victim_set;
  dcache_word_index_t victim_word;
  core_data_t victim_data[DCACHE_WAY_COUNT];
  logic data_write, metadata_write, metadata_present, metadata_dirty, installed;
  dcache_set_index_t data_set, metadata_set, installed_set;
  dcache_way_index_t data_way, metadata_way, installed_way;
  dcache_word_index_t data_word;
  core_data_t data_value;
  core_byte_strobe_t data_strobe;
  dcache_tag_t metadata_tag;
  dcache_refill_req_t refill_request;
  dcache_refill_resp_t refill_response;
  logic refill_valid, refill_ready=0, refill_response_valid=0, refill_response_ready;
  dcache_writeback_req_t writeback_request;
  dcache_writeback_resp_t writeback_response;
  dcache_line_data_t writeback_line;
  logic writeback_valid, writeback_ready=0, writeback_response_valid=0, writeback_response_ready;
  int responses=0, installs=0, clean_completions=0, cases=0;

  riscv32_dcache_miss_unit dut (
      .clk_i(clk), .rst_ni(rst_n), .miss_req_i(request), .miss_req_valid_i(request_valid),
      .miss_req_ready_o(request_ready), .miss_resp_o(response), .miss_resp_valid_o(response_valid),
      .miss_resp_ready_i(response_ready), .clean_req_valid_i(clean_valid), .clean_req_ready_o(clean_ready),
      .clean_set_index_i(dcache_set_index_t'(1)), .clean_way_index_i(dcache_way_index_t'(0)),
      .clean_tag_i(dcache_tag_t'(3)), .clean_done_o(clean_done), .clean_access_fault_o(clean_fault),
      .victim_read_enable_o(victim_read), .victim_read_set_index_o(victim_set),
      .victim_read_word_index_o(victim_word), .victim_read_word_data_array_i(victim_data),
      .data_write_valid_o(data_write), .data_write_set_index_o(data_set), .data_write_way_index_o(data_way),
      .data_write_word_index_o(data_word), .data_write_word_data_o(data_value),
      .data_write_byte_strobe_o(data_strobe), .metadata_write_valid_o(metadata_write),
      .metadata_write_set_index_o(metadata_set), .metadata_write_way_index_o(metadata_way),
      .metadata_write_tag_o(metadata_tag), .metadata_write_line_present_o(metadata_present),
      .metadata_write_line_dirty_o(metadata_dirty), .line_install_event_o(installed),
      .installed_set_index_o(installed_set), .installed_way_index_o(installed_way),
      .transaction_present_o(busy), .refill_req_o(refill_request), .refill_req_valid_o(refill_valid),
      .refill_req_ready_i(refill_ready), .refill_resp_i(refill_response),
      .refill_resp_valid_i(refill_response_valid), .refill_resp_ready_o(refill_response_ready),
      .writeback_line_data_o(writeback_line), .writeback_req_o(writeback_request),
      .writeback_req_valid_o(writeback_valid), .writeback_req_ready_i(writeback_ready),
      .writeback_resp_i(writeback_response), .writeback_resp_valid_i(writeback_response_valid),
      .writeback_resp_ready_o(writeback_response_ready)
  );

  always @(posedge clk) begin
    if (victim_read)
      for (int way=0; way<DCACHE_WAY_COUNT; way++)
        victim_data[way] <= core_data_t'(32'h12000000 + int'(victim_word));
    if (rst_n) begin
      if (response_valid && response_ready) responses++;
      if (installed) installs++;
      if (clean_done) clean_completions++;
    end
  end

  task automatic accept_writeback;
    while (!writeback_valid) @(negedge clk);
    for (int word_index=0; word_index<DCACHE_WORDS_PER_LINE; word_index++)
      assert(writeback_line[word_index*CORE_DATA_WIDTH+:CORE_DATA_WIDTH]==
             core_data_t'(32'h12000000+word_index))
        else $fatal(1,"victim capture lost a word");
    writeback_ready=1;
    @(negedge clk); writeback_ready=0;
  endtask

  task automatic check_miss(input bit dirty, input int b_order, input bit b_fault,
                            input int r_fault_word, input int critical, input bit stall_response);
    int before_responses, before_installs;
    bit expected_fault;
    data_memory_resp_t held;
    before_responses=responses;
    before_installs=installs;
    expected_fault=b_fault || r_fault_word>=0;
    @(negedge clk);
    request='0;
    request.memory_req.addr=phys_addr_t'(32'h80000100);
    request.memory_req.cmd=MEM_CMD_LOAD;
    request.memory_req.transaction_id=mem_txn_id_t'(7);
    request.word_index=dcache_word_index_t'(critical);
    request.victim_present=dirty;
    request.victim_dirty=dirty;
    request.requested_tag=dcache_tag_t'(8);
    request_valid=1;
    refill_ready=!dirty;
    response_ready=!stall_response;
    #1;
    assert(request_ready && (dirty ? victim_read : refill_valid))
      else $fatal(1,"miss allocation inserted a request/read bubble");
    @(negedge clk); request_valid=0; refill_ready=0;
    if (dirty) begin
      accept_writeback();
      while (!refill_valid) @(negedge clk);
      refill_ready=1;
      @(negedge clk); refill_ready=0;
    end
    writeback_response='0;
    writeback_response.access_fault=b_fault;
    if (dirty && b_order==0) begin
      writeback_response_valid=1;
      @(negedge clk); writeback_response_valid=0;
    end
    for (int word_index=0; word_index<DCACHE_WORDS_PER_LINE; word_index++) begin
      refill_response='0;
      refill_response.word_index=dcache_word_index_t'(word_index);
      refill_response.word_data=core_data_t'(32'h34000000+word_index);
      refill_response.access_fault=word_index==r_fault_word;
      refill_response.last_word=word_index==DCACHE_WORDS_PER_LINE-1;
      refill_response_valid=1;
      writeback_response_valid=dirty && b_order==1 && refill_response.last_word;
      #1;
      assert(refill_response_ready) else $fatal(1,"response backpressure blocked refill drain");
      if (refill_response.last_word && (!dirty || b_order!=2)) begin
        assert(response_valid && response.access_fault==expected_fault)
          else $fatal(1,"last R did not produce immediate completion");
      end else begin
        assert(!response_valid) else $fatal(1,"miss completed before all required bus responses");
      end
      @(negedge clk);
      refill_response_valid=0; writeback_response_valid=0;
    end
    if (dirty && b_order==2) begin
      repeat(2) begin
        #1; assert(!response_valid && installs==before_installs)
          else $fatal(1,"late B was not awaited");
        @(negedge clk);
      end
      writeback_response_valid=1;
      #1; assert(response_valid && response.access_fault==expected_fault)
        else $fatal(1,"last B did not produce immediate completion");
      @(negedge clk); writeback_response_valid=0;
    end
    if (stall_response) begin
      held=response;
      assert(response_valid && held.transaction_id==mem_txn_id_t'(7) &&
             held.read_data==core_data_t'(32'h34000000+critical) && held.access_fault==expected_fault)
        else $fatal(1,"saved completion mismatch");
      repeat(3) begin
        @(negedge clk);
        assert(response_valid && response===held) else $fatal(1,"completion changed under stall");
      end
      response_ready=1;
      @(negedge clk);
    end
    response_ready=0;
    assert(responses==before_responses+1 && installs==before_installs+int'(!expected_fault))
      else $fatal(1,"wrong response/install count");
    assert(!busy) else $fatal(1,"completed miss kept transaction busy");
    cases++;
  endtask

  task automatic check_clean(input bit fault);
    int before_done;
    before_done=clean_completions;
    @(negedge clk); clean_valid=1;
    #1; assert(clean_ready && victim_read) else $fatal(1,"clean did not start victim read immediately");
    @(negedge clk); clean_valid=0;
    accept_writeback();
    writeback_response='0;
    writeback_response.access_fault=fault;
    writeback_response_valid=1;
    #1;
    assert(clean_done && clean_fault==fault && metadata_write==!fault && !metadata_dirty)
      else $fatal(1,"clean completion/metadata did not match B response");
    @(negedge clk); writeback_response_valid=0;
    assert(!busy && clean_completions==before_done+1) else $fatal(1,"clean completion repeated");
    cases++;
  endtask

  initial begin
    request='0; refill_response='0; writeback_response='0;
    repeat(3) @(negedge clk); rst_n=1;
    for (int stall=0; stall<2; stall++) begin
      check_miss(0,0,0,-1,0,1'(stall));
      check_miss(0,0,0,0,DCACHE_WORDS_PER_LINE-1,1'(stall));
      for (int order=0; order<3; order++) begin
        check_miss(1,order,0,-1,DCACHE_WORDS_PER_LINE-1,1'(stall));
        check_miss(1,order,1,-1,0,1'(stall));
        check_miss(1,order,0,DCACHE_WORDS_PER_LINE-1,0,1'(stall));
      end
    end
    check_clean(0); check_clean(1);
    $display("PASS D-cache miss contract: %0d cases, R/B order, faults, response stalls, allocation bypass, clean",cases);
    $finish;
  end
  initial begin #1000000; $fatal(1,"D-cache miss contract timeout"); end
endmodule
