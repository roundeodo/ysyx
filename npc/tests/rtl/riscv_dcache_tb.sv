module riscv_dcache_tb;
  import riscv_pkg::*;
  import riscv_addr_map_pkg::*;
  import riscv_axi4_pkg::*;

  localparam int unsigned TEST_MEMORY_BYTES = 32'h0001_0000;
  localparam phys_addr_t TEST_ADDR_A = phys_addr_t'(32'h8000_0100);
  localparam phys_addr_t SAME_SET_ADDR_STRIDE = phys_addr_t'(DCACHE_SET_COUNT * DCACHE_LINE_BYTES);
  localparam phys_addr_t TEST_ADDR_B = TEST_ADDR_A + SAME_SET_ADDR_STRIDE;
  localparam phys_addr_t TEST_ADDR_C = TEST_ADDR_B + SAME_SET_ADDR_STRIDE;
  localparam mem_size_e TEST_WORD_SIZE = (CORE_DATA_WIDTH == 64) ? MEM_SIZE_DOUBLE : MEM_SIZE_WORD;

  // 每项事务启动前配置注入；事务进行期间保持这些条件不变。
  bit inject_read_error;
  bit inject_write_error;
  bit align_write_response_with_read_last;
  int unsigned read_response_delay;
  int unsigned write_response_delay;
  int unsigned write_data_gap;
  int unsigned write_data_delay_q;
  int unsigned response_stall_cycles;
  int unsigned read_delay_q, write_delay_q;
  bit read_last_occurred_q;
  int unsigned cycle_count, read_last_cycle, write_response_cycle;

  logic clk;
  logic rst_ni;

  data_memory_req_t data_memory_req;
  logic data_memory_req_valid;
  logic data_memory_req_ready;
  data_memory_resp_t data_memory_resp;
  logic data_memory_resp_valid;
  logic data_memory_resp_ready;

  bit maintenance_test_active;
  logic fence_i_committed;
  logic maintenance_clean_req;
  logic maintenance_invalidate_req;
  logic maintenance_active;
  logic invalidate_done;
  logic clean_req;
  logic clean_done;
  logic clean_access_fault;
  logic cache_busy;
  dcache_event_t dcache_event;

  axi4_manager_to_target_t axi_manager;
  axi4_target_to_manager_t axi_target;

  logic [7:0] memory_byte_array[TEST_MEMORY_BYTES];
  logic read_transaction_present_q;
  axi4_addr_t read_base_addr_q;
  logic [7:0] read_len_q;
  logic [7:0] read_beat_index_q;
  axi4_id_t read_id_q;

  logic write_transaction_present_q;
  axi4_addr_t write_base_addr_q;
  logic [7:0] write_beat_index_q;
  axi4_id_t write_id_q;
  logic write_response_present_q;

  int unsigned read_address_handshake_count;
  int unsigned write_address_handshake_count;
  logic dirty_miss_read_write_overlap_observed_q;

  riscv_dcache u_dut (
      .clk_i                   (clk),
      .rst_ni                  (rst_ni),
      .data_memory_req_i       (data_memory_req),
      .data_memory_req_valid_i (data_memory_req_valid),
      .data_memory_req_ready_o (data_memory_req_ready),
      .data_memory_resp_o      (data_memory_resp),
      .data_memory_resp_valid_o(data_memory_resp_valid),
      .data_memory_resp_ready_i(data_memory_resp_ready),
      .clean_req_i             (maintenance_test_active ? maintenance_clean_req : clean_req),
      .clean_done_o            (clean_done),
      .clean_access_fault_o    (clean_access_fault),
      .cache_busy_o            (cache_busy),
      .event_o                 (dcache_event),
      .axi_manager_o           (axi_manager),
      .axi_manager_i           (axi_target)
  );

  riscv_cache_maintenance_controller u_maintenance (
      .clk_i(clk),
      .rst_ni(rst_ni),
      .fence_i_committed_i(fence_i_committed),
      .dcache_clean_done_i(clean_done),
      .dcache_clean_access_fault_i(clean_access_fault),
      .icache_invalidate_done_i(invalidate_done),
      .dcache_clean_req_o(maintenance_clean_req),
      .icache_invalidate_req_o(maintenance_invalidate_req),
      .maintenance_active_o(maintenance_active)
  );

  always #5 clk = ~clk;

  function automatic axi4_data_t read_memory_word(input axi4_addr_t addr);
    axi4_data_t word_data;
    word_data = '0;
    for (int unsigned byte_index = 0; byte_index < AXI4_STRB_WIDTH; byte_index++) begin
      word_data[byte_index*8+:8] =
          memory_byte_array[(int'(addr[15:0]) + byte_index) % TEST_MEMORY_BYTES];
    end
    return word_data;
  endfunction

  always_comb begin
    axi_target          = '0;
    axi_target.ar_ready = !read_transaction_present_q;
    axi_target.r_valid  = read_transaction_present_q && read_delay_q == 0;
    axi_target.r.data   =
        read_memory_word(read_base_addr_q + axi4_addr_t'(read_beat_index_q * AXI4_STRB_WIDTH));
    axi_target.r.id     = read_id_q;
    axi_target.r.resp   = (inject_read_error && read_beat_index_q == 1) ? AXI4_RESP_SLVERR : AXI4_RESP_OKAY;
    axi_target.r.last   = read_beat_index_q == read_len_q;

    // WREADY只在AW完成后拉高，刻意验证D-cache adapter正确处理独立AW/W握手。
    axi_target.aw_ready = !write_transaction_present_q && !write_response_present_q;
    axi_target.w_ready  = write_transaction_present_q && write_data_delay_q == 0;
    axi_target.b_valid  = write_response_present_q && write_delay_q == 0 &&
        (!align_write_response_with_read_last || read_last_occurred_q ||
         (axi_target.r_valid && axi_target.r.last));
    axi_target.b.id     = write_id_q;
    axi_target.b.resp   = inject_write_error ? AXI4_RESP_SLVERR : AXI4_RESP_OKAY;
  end

  always_ff @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      read_transaction_present_q   <= 1'b0;
      read_base_addr_q             <= '0;
      read_len_q                   <= '0;
      read_beat_index_q            <= '0;
      read_id_q                    <= '0;
      read_address_handshake_count <= 0;
    end else begin
      if (axi_manager.ar_valid && axi_target.ar_ready) begin
        read_transaction_present_q   <= 1'b1;
        read_base_addr_q             <= axi_manager.ar.addr;
        read_len_q                   <= axi_manager.ar.len;
        read_beat_index_q            <= '0;
        read_id_q                    <= axi_manager.ar.id;
        read_address_handshake_count <= read_address_handshake_count + 1;
      end

      if (axi_target.r_valid && axi_manager.r_ready) begin
        if (axi_target.r.last) begin
          read_transaction_present_q <= 1'b0;
        end else begin
          read_beat_index_q <= read_beat_index_q + 8'd1;
        end
      end
    end
  end

  // dirty victim尚在W/B通道推进时，新line的AR已经完成握手，证明两个方向没有串行化。
  always_ff @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      dirty_miss_read_write_overlap_observed_q <= 1'b0;
    end else if (axi_manager.ar_valid && axi_target.ar_ready &&
                 (write_transaction_present_q || write_response_present_q)) begin
      dirty_miss_read_write_overlap_observed_q <= 1'b1;
    end
  end

  always_ff @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      write_transaction_present_q   <= 1'b0;
      write_base_addr_q             <= '0;
      write_beat_index_q            <= '0;
      write_id_q                    <= '0;
      write_response_present_q      <= 1'b0;
      write_address_handshake_count <= 0;
    end else begin
      if (axi_manager.aw_valid && axi_target.aw_ready) begin
        write_transaction_present_q   <= 1'b1;
        write_base_addr_q             <= axi_manager.aw.addr;
        write_beat_index_q            <= '0;
        write_id_q                    <= axi_manager.aw.id;
        write_address_handshake_count <= write_address_handshake_count + 1;
      end

      if (axi_manager.w_valid && axi_target.w_ready) begin
        for (int unsigned byte_index = 0; byte_index < AXI4_STRB_WIDTH; byte_index++) begin
          if (axi_manager.w.strb[byte_index] && !inject_write_error) begin
            memory_byte_array[
                (int'(write_base_addr_q[15:0]) +
                 int'(write_beat_index_q) * AXI4_STRB_WIDTH + byte_index) %
                TEST_MEMORY_BYTES
            ] <= axi_manager.w.data[byte_index*8+:8];
          end
        end

        if (axi_manager.w.last) begin
          write_transaction_present_q <= 1'b0;
          write_response_present_q    <= 1'b1;
        end else begin
          write_beat_index_q <= write_beat_index_q + 8'd1;
        end
      end

      if (axi_target.b_valid && axi_manager.b_ready) begin
        write_response_present_q <= 1'b0;
      end
    end
  end

  // 延迟和时间戳不改变事务数据，用于覆盖B早于、晚于及同拍于最后一个R。
  always_ff @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      read_delay_q         <= 0;
      write_delay_q        <= 0;
      read_last_occurred_q <= 0;
      cycle_count          <= 0;
      write_data_delay_q   <= 0;
      read_last_cycle      <= 0;
      write_response_cycle <= 0;
    end else begin
      cycle_count <= cycle_count + 1;
      if (write_data_delay_q != 0) write_data_delay_q <= write_data_delay_q - 1;
      if (axi_manager.w_valid && axi_target.w_ready) write_data_delay_q <= write_data_gap;
      if (read_delay_q != 0) read_delay_q <= read_delay_q - 1;
      if (write_delay_q != 0) write_delay_q <= write_delay_q - 1;
      if (axi_manager.ar_valid && axi_target.ar_ready) begin
        read_delay_q         <= read_response_delay;
        read_last_occurred_q <= 0;
      end
      if (axi_manager.w_valid && axi_target.w_ready && axi_manager.w.last)
        write_delay_q <= write_response_delay;
      if (axi_target.r_valid && axi_manager.r_ready && axi_target.r.last) begin
        read_last_occurred_q <= 1;
        read_last_cycle      <= cycle_count;
      end
      if (axi_target.b_valid && axi_manager.b_ready) write_response_cycle <= cycle_count;
    end
  end

  initial begin
    #1000000;
    $fatal(1, "D-cache directed test timed out");
  end

  task automatic reset_cache;
    @(negedge clk);
    rst_ni                              = 0;
    maintenance_test_active             = 0;
    fence_i_committed                   = 0;
    invalidate_done                     = 0;
    data_memory_req_valid               = 0;
    data_memory_resp_ready              = 1;
    clean_req                           = 0;
    inject_read_error                   = 0;
    inject_write_error                  = 0;
    align_write_response_with_read_last = 0;
    read_response_delay                 = 0;
    write_response_delay                = 0;
    write_data_gap                      = 0;
    response_stall_cycles               = 0;
    repeat (3) @(negedge clk);
    rst_ni = 1;
  endtask

  task automatic issue_memory_request(
      input phys_addr_t addr, input mem_cmd_e cmd, input core_data_t write_data,
      input core_byte_strobe_t byte_strobe, input mem_txn_id_t transaction_id,
      output core_data_t read_data, input bit expected_fault = 0);
    data_memory_resp_t held_response;
    @(negedge clk);
    data_memory_req                = '0;
    data_memory_req.addr           = addr;
    data_memory_req.cmd            = cmd;
    data_memory_req.size           = TEST_WORD_SIZE;
    data_memory_req.write_data     = write_data;
    data_memory_req.byte_strobe    = byte_strobe;
    data_memory_req.transaction_id = transaction_id;
    data_memory_req_valid          = 1'b1;
    data_memory_resp_ready         = response_stall_cycles == 0;

    while (!data_memory_req_ready) @(negedge clk);
    @(negedge clk);
    data_memory_req_valid = 1'b0;

    while (!data_memory_resp_valid) @(negedge clk);
    held_response = data_memory_resp;
    for (int unsigned stall_cycle = 0; stall_cycle < response_stall_cycles; stall_cycle++) begin
      // 请求已经握手。无效输入分别跨word、跨set变化，不能影响待消费的响应。
      data_memory_req.addr = addr + phys_addr_t'((stall_cycle + 1) * CORE_DATA_BYTE_COUNT);
      @(negedge clk);
      assert (data_memory_resp_valid && data_memory_resp == held_response)
      else $fatal(1, "D-cache response changed under backpressure");
    end
    data_memory_resp_ready = 1;
    assert (data_memory_resp.access_fault == expected_fault)
    else $fatal(1, "D-cache access-fault status mismatch");
    assert (data_memory_resp.transaction_id == transaction_id)
    else $fatal(1, "D-cache response transaction ID mismatch");
    read_data = data_memory_resp.read_data;
    @(negedge clk);
  endtask

  task automatic check_valid_next_lookup_under_backpressure;
    core_data_t expected_a;
    expected_a = core_data_t'(read_memory_word(axi4_addr_t'(TEST_ADDR_A)));
    @(negedge clk);
    data_memory_resp_ready         = 0;
    data_memory_req                = '0;
    data_memory_req.addr           = TEST_ADDR_A;
    data_memory_req.cmd            = MEM_CMD_LOAD;
    data_memory_req.size           = TEST_WORD_SIZE;
    data_memory_req.transaction_id = mem_txn_id_t'(9);
    data_memory_req_valid          = 1;
    while (!data_memory_req_ready) @(negedge clk);
    @(negedge clk);
    data_memory_req.addr           = TEST_ADDR_B + phys_addr_t'(CORE_DATA_BYTE_COUNT);
    data_memory_req.transaction_id = mem_txn_id_t'(10);
    repeat (3) begin
      assert (!data_memory_req_ready && data_memory_resp_valid &&
              data_memory_resp.transaction_id == mem_txn_id_t'(9) &&
              data_memory_resp.read_data == expected_a)
      else $fatal(1, "unaccepted valid lookup changed the previous response");
      @(negedge clk);
    end
    data_memory_resp_ready = 1;
    @(negedge clk);
    data_memory_req_valid = 0;
    assert (data_memory_resp_valid && data_memory_resp.transaction_id == mem_txn_id_t'(10) &&
            data_memory_resp.read_data == core_data_t'(read_memory_word(
        axi4_addr_t'(TEST_ADDR_B + phys_addr_t'(CORE_DATA_BYTE_COUNT))
    )))
    else $fatal(1, "pending lookup did not complete after response backpressure ended");
    @(negedge clk);
  endtask

  task automatic clean_cache;
    @(negedge clk);
    clean_req = 1'b1;
    while (!clean_done) @(negedge clk);
    assert (!clean_access_fault)
    else $fatal(1, "D-cache clean returned an unexpected access fault");
    @(negedge clk);
    clean_req = 1'b0;
  endtask

  // 连续发出store hit和同地址load。第二个请求必须与store响应同拍握手，下一拍
  // 返回的数据必须经过显式read-during-write bypass看到刚写入的值。
  task automatic issue_store_then_load_without_gap(
      input phys_addr_t addr, input core_data_t store_data, output core_data_t load_data,
      input core_byte_strobe_t store_strobe = '1,
      input phys_addr_t following_load_addr = TEST_ADDR_A, input bit following_load_hits = 1);
    @(negedge clk);
    data_memory_req                = '0;
    data_memory_req.addr           = addr;
    data_memory_req.cmd            = MEM_CMD_STORE;
    data_memory_req.size           = TEST_WORD_SIZE;
    data_memory_req.write_data     = store_data;
    data_memory_req.byte_strobe    = store_strobe;
    data_memory_req.transaction_id = mem_txn_id_t'(3);
    data_memory_req_valid          = 1'b1;

    while (!data_memory_req_ready) @(negedge clk);
    @(negedge clk);
    assert (data_memory_resp_valid && data_memory_resp.transaction_id == mem_txn_id_t'(3))
    else $fatal(1, "D-cache store hit did not respond before rollover lookup");

    data_memory_req                = '0;
    data_memory_req.addr           = following_load_addr;
    data_memory_req.cmd            = MEM_CMD_LOAD;
    data_memory_req.size           = TEST_WORD_SIZE;
    data_memory_req.transaction_id = mem_txn_id_t'(4);
    assert (data_memory_req_ready)
    else $fatal(1, "D-cache inserted a fixed bubble after a store hit");

    @(negedge clk);
    data_memory_req_valid = 1'b0;
    if (!following_load_hits) while (!data_memory_resp_valid) @(negedge clk);
    assert (data_memory_resp_valid && data_memory_resp.transaction_id == mem_txn_id_t'(4))
    else $fatal(1, "D-cache rollover load did not respond on the next cycle");
    assert (!data_memory_resp.access_fault)
    else $fatal(1, "D-cache rollover load returned an unexpected access fault");
    load_data              = data_memory_resp.read_data;
    data_memory_resp_ready = 0;
    repeat (3) begin
      data_memory_req.addr = data_memory_req.addr + phys_addr_t'(DCACHE_LINE_BYTES);
      @(negedge clk);
      assert (data_memory_resp_valid && data_memory_resp.read_data == load_data)
      else $fatal(1, "store-to-load bypass did not survive backpressure");
    end
    data_memory_resp_ready = 1;
    @(negedge clk);
  endtask

  initial begin
    core_data_t  read_data;
    core_data_t  original_a;
    core_data_t  original_b;
    core_data_t  original_c;
    core_data_t  stored_a;
    core_data_t  stored_c;
    int unsigned read_count_after_first_miss;

    clk                    = 1'b0;
    rst_ni                 = 1'b0;
    data_memory_req        = '0;
    data_memory_req_valid  = 1'b0;
    data_memory_resp_ready = 1'b1;
    clean_req              = 1'b0;

    for (int unsigned byte_addr = 0; byte_addr < TEST_MEMORY_BYTES; byte_addr++) begin
      memory_byte_array[byte_addr] = 8'(byte_addr) ^ 8'h5a;
    end

    original_a = core_data_t'(read_memory_word(axi4_addr_t'(TEST_ADDR_A)));
    original_b = core_data_t'(read_memory_word(axi4_addr_t'(TEST_ADDR_B)));
    original_c = core_data_t'(read_memory_word(axi4_addr_t'(TEST_ADDR_C)));
    stored_a   = core_data_t'(64'h8877_6655_4433_2211);
    stored_c   = core_data_t'(64'h1020_3040_5060_7080);

    repeat (4) @(posedge clk);
    rst_ni = 1'b1;

    issue_memory_request(TEST_ADDR_A, MEM_CMD_LOAD, '0, '0, mem_txn_id_t'(1), read_data);
    assert (read_data == original_a)
    else $fatal(1, "D-cache refill returned incorrect data for line A");
    assert (read_address_handshake_count == 1)
    else $fatal(1, "first D-cache load did not issue exactly one AXI burst");

    read_count_after_first_miss = read_address_handshake_count;
    issue_memory_request(TEST_ADDR_A, MEM_CMD_LOAD, '0, '0, mem_txn_id_t'(2), read_data);
    assert (read_data == original_a)
    else $fatal(1, "D-cache hit returned incorrect data for line A");
    assert (read_address_handshake_count == read_count_after_first_miss)
    else $fatal(1, "D-cache hit incorrectly issued an AXI read");

    issue_store_then_load_without_gap(TEST_ADDR_A, stored_a, read_data);
    assert (write_address_handshake_count == 0)
    else $fatal(1, "write-back D-cache wrote a store hit to AXI immediately");
    assert (read_data == stored_a)
    else $fatal(1, "D-cache load did not observe a preceding store hit");

    issue_memory_request(TEST_ADDR_B, MEM_CMD_LOAD, '0, '0, mem_txn_id_t'(5), read_data);
    assert (read_data == original_b)
    else $fatal(1, "D-cache refill returned incorrect data for line B");
    issue_memory_request(TEST_ADDR_C, MEM_CMD_LOAD, '0, '0, mem_txn_id_t'(6), read_data);
    assert (read_data == original_c)
    else $fatal(1, "D-cache refill returned incorrect data for line C");
    assert (write_address_handshake_count == 1)
    else $fatal(1, "dirty conflict victim was not written back exactly once");
    assert (dirty_miss_read_write_overlap_observed_q)
    else $fatal(1, "dirty miss serialized refill behind the complete writeback response");
    assert (core_data_t'(read_memory_word(axi4_addr_t'(TEST_ADDR_A))) == stored_a)
    else $fatal(1, "dirty victim writeback did not update backing memory");

    issue_memory_request(TEST_ADDR_C, MEM_CMD_STORE, stored_c, '1, mem_txn_id_t'(7), read_data);
    clean_cache();
    assert (write_address_handshake_count == 2)
    else $fatal(1, "D-cache clean did not write back the remaining dirty line");
    assert (core_data_t'(read_memory_word(axi4_addr_t'(TEST_ADDR_C))) == stored_c)
    else $fatal(1, "D-cache clean did not update backing memory");

    // 命中、缺失及错误响应都必须在反压期间保持。跨一整行改变无效输入地址。
    response_stall_cycles = DCACHE_WORDS_PER_LINE + 2;
    issue_memory_request(TEST_ADDR_C, MEM_CMD_LOAD, '0, '0, mem_txn_id_t'(8), read_data);
    assert (read_data == stored_c)
    else $fatal(1, "stalled hit returned wrong data");

    // 在三种B/R完成顺序下分别注入B错误、R错误和双向错误。
    for (int unsigned error_kind = 1; error_kind <= 3; error_kind++) begin
      for (int unsigned completion_order = 0; completion_order < 3; completion_order++) begin
        reset_cache();
        for (int unsigned word_index = 0; word_index < DCACHE_WORDS_PER_LINE; word_index++) begin
          issue_memory_request(TEST_ADDR_A + phys_addr_t'(word_index * CORE_DATA_BYTE_COUNT),
                               MEM_CMD_STORE, stored_a ^ core_data_t'(word_index), '1,
                               mem_txn_id_t'(word_index), read_data);
        end
        issue_memory_request(TEST_ADDR_B, MEM_CMD_LOAD, '0, '0, mem_txn_id_t'(1), read_data);
        inject_write_error                  = error_kind != 2;
        inject_read_error                   = error_kind != 1;
        read_response_delay                 = completion_order == 0 ? 24 : 0;
        write_response_delay                = completion_order == 1 ? 24 : 0;
        align_write_response_with_read_last = completion_order == 2;
        response_stall_cycles               = 3;
        issue_memory_request(TEST_ADDR_C, MEM_CMD_LOAD, '0, '0, mem_txn_id_t'(2), read_data, 1);
        case (completion_order)
          0:
          assert (write_response_cycle < read_last_cycle)
          else $fatal(1, "B-before-R coverage missed");
          1:
          assert (write_response_cycle > read_last_cycle)
          else $fatal(1, "B-after-R coverage missed");
          2:
          assert (write_response_cycle == read_last_cycle)
          else $fatal(1, "B-with-R coverage missed");
        endcase
        inject_write_error                  = 0;
        inject_read_error                   = 0;
        align_write_response_with_read_last = 0;
        read_response_delay                 = 0;
        write_response_delay                = 0;
        write_data_gap                      = 0;
        for (int unsigned word_index = 0; word_index < DCACHE_WORDS_PER_LINE; word_index++) begin
          issue_memory_request(TEST_ADDR_A + phys_addr_t'(word_index * CORE_DATA_BYTE_COUNT),
                               MEM_CMD_LOAD, '0, '0, mem_txn_id_t'(word_index), read_data);
          assert (read_data == (stored_a ^ core_data_t'(word_index)))
          else
            $fatal(
                1,
                "dirty data lost after error: kind=%0d order=%0d word=%0d",
                error_kind,
                completion_order,
                word_index
            );
        end
        clean_cache();
        for (int unsigned word_index = 0; word_index < DCACHE_WORDS_PER_LINE; word_index++) begin
          assert (core_data_t'(read_memory_word(
              axi4_addr_t'(TEST_ADDR_A + phys_addr_t'(word_index * CORE_DATA_BYTE_COUNT))
          )) == (stored_a ^ core_data_t'(word_index)))
          else $fatal(1, "restored dirty line could not be written back");
        end
      end
    end

    // 部分字节store的相邻load旁路，包含多拍反压；未选中的字节必须保留。
    reset_cache();
    issue_memory_request(TEST_ADDR_A, MEM_CMD_LOAD, '0, '0, mem_txn_id_t'(1), original_a);
    for (int unsigned byte_index = 0; byte_index < CORE_DATA_BYTE_COUNT; byte_index++) begin
      issue_store_then_load_without_gap(TEST_ADDR_A, ~stored_a, read_data,
                                        core_byte_strobe_t'(1) << byte_index);
      original_a[byte_index*8+:8] = ~stored_a[byte_index*8+:8];
      assert (read_data == original_a)
      else $fatal(1, "partial-store bypass changed unselected bytes");
    end

    // 缓存满时，store响应与同组miss同拍接收。替换逻辑必须前递刚置位的dirty状态。
    reset_cache();
    issue_memory_request(TEST_ADDR_A, MEM_CMD_LOAD, '0, '0, mem_txn_id_t'(1), read_data);
    issue_memory_request(TEST_ADDR_B, MEM_CMD_LOAD, '0, '0, mem_txn_id_t'(2), read_data);
    check_valid_next_lookup_under_backpressure();
    write_data_gap = 2;
    issue_store_then_load_without_gap(TEST_ADDR_A, stored_a, read_data, '1, TEST_ADDR_C, 0);
    assert (write_address_handshake_count == 1 && core_data_t'(read_memory_word(
        axi4_addr_t'(TEST_ADDR_A)
    )) == stored_a)
    else $fatal(1, "store-to-miss dirty-bit forwarding lost a writeback");
    // 为维护重试留下已知脏行。
    original_a = ~stored_a;
    issue_memory_request(TEST_ADDR_C, MEM_CMD_STORE, original_a, '1, mem_txn_id_t'(3), read_data);

    // 同一维护操作连续遇到三次写回失败，前端必须一直保持阻塞；随后成功才允许失效I-cache。
    maintenance_test_active = 1;
    inject_write_error      = 1;
    fence_i_committed       = 1;
    @(negedge clk);
    fence_i_committed = 0;
    for (int unsigned retry = 0; retry < 3; retry++) begin
      while (!clean_done) begin
        assert (maintenance_active && !maintenance_invalidate_req)
        else $fatal(1, "maintenance released fetch before dirty data was written back");
        @(negedge clk);
      end
      assert (clean_access_fault)
      else $fatal(1, "clean fault injection was not observed");
      @(negedge clk);
      assert (maintenance_active && !maintenance_invalidate_req && !maintenance_clean_req)
      else $fatal(1, "failed clean did not enter the request-release retry cycle");
    end
    inject_write_error = 0;
    while (!maintenance_invalidate_req) @(negedge clk);
    assert (core_data_t'(read_memory_word(axi4_addr_t'(TEST_ADDR_C))) == original_a)
    else $fatal(1, "maintenance retried without preserving dirty bytes");
    repeat (3) begin
      @(negedge clk);
      assert (maintenance_active && maintenance_invalidate_req)
      else $fatal(1, "maintenance failed to wait for I-cache invalidation");
    end
    invalidate_done = 1;
    @(negedge clk);
    invalidate_done = 0;
    assert (!maintenance_active)
    else $fatal(1, "successful maintenance did not resume fetch");

    $display("D-cache directed test passed: XLEN=%0d sets=%0d ways=%0d line=%0dB", XLEN,
             DCACHE_SET_COUNT, DCACHE_WAY_COUNT, DCACHE_LINE_BYTES);
    $finish;
  end

endmodule
