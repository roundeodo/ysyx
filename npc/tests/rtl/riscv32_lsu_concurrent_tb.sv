// LSU + PMA route + D-cache integration. Requests and returns are checked by PC,
// independently of the implementation's dynamically allocated transaction slots.
module riscv32_lsu_concurrent_tb;
  import riscv32_pkg::*;
  import riscv32_addr_map_pkg::*;
  import riscv32_axi4_pkg::*;
  logic clk = 0, rst_ni = 0;
  always #5 clk = ~clk;
  lsu_req_t request;
  logic request_valid = 0, request_ready, busy;
  mem_txn_id_t request_id, result_id;
  writeback_result_t result;
  logic result_valid, result_ready = 1;
  data_memory_req_t memory_request;
  data_memory_resp_t memory_response;
  logic memory_valid, memory_ready, response_valid, response_ready;
  axi4_manager_to_target_t axi;
  axi4_target_to_manager_t target;
  dcache_event_t event_record;
  logic clean = 0, clean_done, clean_fault, cache_busy;
  riscv32_lsu u_lsu (
    .clk_i(clk), .rst_ni, .lsu_req_i(request), .lsu_req_valid_i(request_valid),
    .lsu_req_ready_o(request_ready), .lsu_req_id_o(request_id), .lsu_transaction_active_o(busy),
    .lsu_pending_writes_rd_o(), .lsu_pending_rd_o(),
    .data_memory_req_o(memory_request), .data_memory_req_valid_o(memory_valid),
    .data_memory_req_ready_i(memory_ready), .data_memory_resp_i(memory_response),
    .data_memory_resp_valid_i(response_valid), .data_memory_resp_ready_o(response_ready),
    .lsu_writeback_o(result), .lsu_writeback_id_o(result_id),
    .lsu_writeback_valid_o(result_valid), .lsu_writeback_ready_i(result_ready));
  riscv32_data_mem u_memory (
    .clk_i(clk), .rst_ni, .data_memory_req_i(memory_request),
    .data_memory_req_valid_i(memory_valid), .data_memory_req_ready_o(memory_ready),
    .data_memory_resp_o(memory_response), .data_memory_resp_valid_o(response_valid),
    .data_memory_resp_ready_i(response_ready), .dcache_clean_req_i(clean),
    .dcache_clean_done_o(clean_done), .dcache_clean_access_fault_o(clean_fault),
    .dcache_busy_o(cache_busy), .dcache_event_o(event_record),
    .axi_manager_o(axi), .axi_manager_i(target));

  logic [31:0] memory[4096];
  logic read_active = 0, write_active = 0, b_valid = 0;
  bit inject_write_error = 0, inject_read_error = 0;
  axi4_addr_t read_addr, write_addr;
  axi4_id_t read_id, write_id;
  logic [7:0] read_len, read_beat, write_beat;
  int read_wait = 0, delay = 30, seed = 1;
  logic [31:0] random_q = 1;
  int cycle_count = 0, reads = 0, returns = 0, serial = 0;
  int miss_rollovers = 0;
  bit expected_present[256], expected_fault[256];
  logic [31:0] expected_data[256];
  int return_order[256];
  always_comb begin
    target = '0;
    target.ar_ready = !read_active && random_q[0];
    target.r_valid = read_active && read_wait == 0;
    target.r.id = read_id;
    target.r.data = memory[(int'(read_addr[13:2]) + int'(read_beat)) % 4096];
    target.r.last = read_beat == read_len;
    target.r.resp = inject_read_error && read_beat == 1 ? AXI4_RESP_SLVERR : AXI4_RESP_OKAY;
    target.aw_ready = !write_active && !b_valid && random_q[1];
    target.w_ready = write_active && random_q[2];
    target.b_valid = b_valid;
    target.b.id = write_id;
    target.b.resp = inject_write_error ? AXI4_RESP_SLVERR : AXI4_RESP_OKAY;
  end
  always @(posedge clk) if (rst_ni) begin
    cycle_count <= cycle_count + 1;
    if (u_memory.gen_dcache.u_dcache.miss_resp_valid &&
        u_memory.gen_dcache.u_dcache.miss_resp_ready && event_record.lookup_event)
      miss_rollovers <= miss_rollovers + 1;
    random_q <= {random_q[30:0], random_q[31] ^ random_q[21] ^ random_q[1] ^ random_q[0]};
    if (read_wait > 0) read_wait <= read_wait - 1;
    if (axi.ar_valid && target.ar_ready) begin
      read_active <= 1; read_addr <= axi.ar.addr; read_len <= axi.ar.len;
      read_id <= axi.ar.id; read_beat <= 0; read_wait <= delay; reads <= reads + 1;
    end
    if (target.r_valid && axi.r_ready) begin
      if (target.r.last) read_active <= 0;
      else begin read_beat <= read_beat + 1'b1; read_wait <= int'(random_q[4:3]); end
    end
    if (axi.aw_valid && target.aw_ready) begin
      write_active <= 1; write_addr <= axi.aw.addr; write_id <= axi.aw.id; write_beat <= 0;
    end
    if (axi.w_valid && target.w_ready) begin
      for (int byte_index = 0; byte_index < 4; byte_index++)
        if (axi.w.strb[byte_index] && !inject_write_error)
          memory[(int'(write_addr[13:2])+int'(write_beat))%4096][byte_index*8+:8]
            <= axi.w.data[byte_index*8+:8];
      if (axi.w.last) begin write_active <= 0; b_valid <= 1; end
      else write_beat <= write_beat + 1'b1;
    end
    if (target.b_valid && axi.b_ready) b_valid <= 0;
    if (result_valid && result_ready) begin
      assert (expected_present[result.uop.pc[9:2]]) else $fatal(1, "duplicate/unowned completion");
      assert (result.uop.exception_valid == expected_fault[result.uop.pc[9:2]])
        else $fatal(1, "wrong fault PC=%x", result.uop.pc);
      if (!result.uop.exception_valid && result.uop.mem_ctrl.cmd == MEM_CMD_LOAD)
        assert (result.result == expected_data[result.uop.pc[9:2]])
          else $fatal(1, "wrong data PC=%x got=%x expected=%x", result.uop.pc,
              result.result, expected_data[result.uop.pc[9:2]]);
      return_order[returns] = int'(result.uop.pc[9:2]);
      returns <= returns + 1;
      expected_present[result.uop.pc[9:2]] = 0;
    end
  end
  task automatic send(input logic [31:0] addr, input logic [31:0] value,
                      input bit store = 0, input bit fault = 0);
    @(negedge clk);
    serial++;
    request = '0;
    request.uop.pc = 32'h8000_0000 + 32'(serial*4);
    request.uop.rd = arch_reg_idx_t'(serial % 31 + 1);
    request.uop.writes_rd = !store;
    request.uop.mem_ctrl.cmd = store ? MEM_CMD_STORE : MEM_CMD_LOAD;
    request.uop.mem_ctrl.size = MEM_SIZE_WORD;
    request.next_pc = request.uop.pc + 4;
    request.effective_addr = addr;
    request.store_data = value;
    request_valid = 1;
    expected_present[serial] = 1;
    expected_data[serial] = value;
    expected_fault[serial] = fault;
    #1;
    while (!request_ready) begin @(negedge clk); #1; end
    @(negedge clk);
    request_valid = 0;
  endtask
  task automatic drain;
    while (busy) @(negedge clk);
    assert (returns == serial) else $fatal(1, "lost completion");
  endtask
  task automatic load(input logic [31:0] addr);
    send(addr, 32'h1234_0000 ^ {18'b0,addr[13:2],2'b0});
  endtask
  initial begin
    int before_returns, before_reads, hit_serial, before_rollovers;
    void'($value$plusargs("seed=%d", seed)); random_q = 32'(seed);
    for (int i=0; i<4096; i++) memory[i] = 32'h1234_0000 ^ 32'(i*4);
    for (int i=0; i<256; i++) expected_present[i] = 0;
    repeat (4) @(negedge clk); rst_ni = 1;
    // Warm two ways in one set. Third line evicts way 0; way 1 must still hit.
    load(32'h80000100); drain(); load(32'h80000180); drain();
    before_returns = returns;
    load(32'h80000200); load(32'h80000180); hit_serial = serial; drain();
    if (DCACHE_HIT_UNDER_MISS && LSU_ENTRIES > 1)
      assert (return_order[before_returns] == hit_serial)
        else $fatal(1, "same-set other-way hit did not overtake miss");
    // Two requests for the same missing line must cause only one refill.
    before_reads = reads;
    load(32'h80000310); load(32'h80000314); drain();
    assert (reads == before_reads + 1) else $fatal(1, "duplicate line refill");
    // Another missing line waits for MSHR availability, then re-reads the arrays.
    before_reads = reads;
    load(32'h80000420); load(32'h80000430); drain();
    assert (reads == before_reads + 2) else $fatal(1, "second miss lost");
    // A hit already displayed under backpressure must survive the miss completion.
    load(32'h80000540); drain();
    result_ready = 0;
    load(32'h80000650); load(32'h80000540);
    repeat (100) @(negedge clk);
    result_ready = 1; drain();
    // A held miss response leaves the arrays free. Releasing it and accepting
    // a queued hit must share one edge instead of inserting an idle cycle.
    result_ready = 0;
    load(32'h80000f70);
    while (!result_valid) @(negedge clk);
    before_rollovers = miss_rollovers;
    load(32'h80000540);
    result_ready = 1;
    drain();
    assert (miss_rollovers == before_rollovers + 1)
      else $fatal(1, "miss completion inserted a redundant lookup bubble");
    // Local alignment exception may complete while an older memory response waits.
    result_ready = 0;
    load(32'h80000760); send(32'h80000003, 0, 0, 1);
    repeat (100) @(negedge clk); result_ready = 1; drain();
    // Hold a memory result, queue a local exception in slot 1, release only
    // the memory result, then reuse slot 0 while the local result is stalled.
    // The new lower slot must not replace the exception already displayed.
    result_ready = 0;
    load(32'h80000f20);
    while (!result_valid) @(negedge clk);
    repeat (2) @(negedge clk);
    send(32'h80000003, 0, 0, 1);
    result_ready = 1; @(negedge clk); result_ready = 0;
    repeat (2) @(negedge clk);
    send(32'h80000007, 0, 0, 1);
    repeat (3) @(negedge clk); result_ready = 1; drain();
    // PMA error waits for cache ownership to drain, then returns its own identity.
    load(32'h80000870); send(32'h70000000, 0, 0, 1); drain();
    // Store hit, subsequent load, dirty eviction and clean retain real data.
    send(32'h80000540, 32'habcdef12, 1); drain();
    send(32'h80000540, 32'habcdef12); drain();
    load(32'h80000940); load(32'h800009c0); drain();
    send(32'h80000540, 32'habcdef12); drain();
    // Failed dirty eviction must restore retired store data before a waiting
    // request for the reserved victim is retried. Also overlap a hit with an R fault.
    send(32'h80000b30, 32'h98765432, 1); drain();
    load(32'h80000bb0); drain();
    inject_write_error = 1;
    send(32'h80000c30, 0, 0, 1);
    send(32'h80000b30, 32'h98765432); drain();
    inject_write_error = 0;
    load(32'h80000d00); drain();
    inject_read_error = 1;
    send(32'h80000e10, 0, 0, 1); load(32'h80000d00); drain();
    inject_read_error = 0;
    clean = 1; while (!clean_done) @(negedge clk);
    assert (!clean_fault) else $fatal(1,"unexpected clean fault");
    @(negedge clk); clean = 0;
    $display("PASS concurrent LSU: seed=%0d entries=%0d hum=%0d cycles=%0d returns=%0d reads=%0d",
        seed, LSU_ENTRIES, DCACHE_HIT_UNDER_MISS, cycle_count, returns, reads);
    $finish;
  end
  initial begin #1000000; $fatal(1, "concurrent LSU timeout"); end
endmodule
