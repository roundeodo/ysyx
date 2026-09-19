module riscv32_dcache_tb;
  import riscv32_pkg::*;
  import riscv32_addr_map_pkg::*;
  import riscv32_axi4_pkg::*;

  localparam int unsigned TEST_MEMORY_BYTES = 32'h0001_0000;
  localparam phys_addr_t TEST_ADDR_A = phys_addr_t'(32'h8000_0100);
  localparam phys_addr_t SAME_SET_ADDR_STRIDE =
      phys_addr_t'(DCACHE_SET_COUNT * DCACHE_LINE_BYTES);
  localparam phys_addr_t TEST_ADDR_B = TEST_ADDR_A + SAME_SET_ADDR_STRIDE;
  localparam phys_addr_t TEST_ADDR_C = TEST_ADDR_B + SAME_SET_ADDR_STRIDE;
  localparam mem_size_e TEST_WORD_SIZE =
      (CORE_DATA_WIDTH == 64) ? MEM_SIZE_DOUBLE : MEM_SIZE_WORD;

  logic clk;
  logic rst_ni;

  data_memory_req_t data_memory_req;
  logic data_memory_req_valid;
  logic data_memory_req_ready;
  data_memory_resp_t data_memory_resp;
  logic data_memory_resp_valid;
  logic data_memory_resp_ready;

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

  riscv32_dcache u_dut (
      .clk_i                    (clk),
      .rst_ni                   (rst_ni),
      .data_memory_req_i        (data_memory_req),
      .data_memory_req_valid_i  (data_memory_req_valid),
      .data_memory_req_ready_o  (data_memory_req_ready),
      .data_memory_resp_o       (data_memory_resp),
      .data_memory_resp_valid_o (data_memory_resp_valid),
      .data_memory_resp_ready_i (data_memory_resp_ready),
      .clean_req_i              (clean_req),
      .clean_done_o             (clean_done),
      .clean_access_fault_o     (clean_access_fault),
      .cache_busy_o             (cache_busy),
      .event_o                  (dcache_event),
      .axi_manager_o            (axi_manager),
      .axi_manager_i            (axi_target)
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
    axi_target = '0;
    axi_target.ar_ready = !read_transaction_present_q;
    axi_target.r_valid = read_transaction_present_q;
    axi_target.r.data = read_memory_word(
        read_base_addr_q + axi4_addr_t'(read_beat_index_q * AXI4_STRB_WIDTH)
    );
    axi_target.r.id = read_id_q;
    axi_target.r.resp = AXI4_RESP_OKAY;
    axi_target.r.last = read_beat_index_q == read_len_q;

    // WREADY只在AW完成后拉高，刻意验证D-cache adapter正确处理独立AW/W握手。
    axi_target.aw_ready = !write_transaction_present_q && !write_response_present_q;
    axi_target.w_ready = write_transaction_present_q;
    axi_target.b_valid = write_response_present_q;
    axi_target.b.id = write_id_q;
    axi_target.b.resp = AXI4_RESP_OKAY;
  end

  always_ff @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      read_transaction_present_q <= 1'b0;
      read_base_addr_q <= '0;
      read_len_q <= '0;
      read_beat_index_q <= '0;
      read_id_q <= '0;
      read_address_handshake_count <= 0;
    end else begin
      if (axi_manager.ar_valid && axi_target.ar_ready) begin
        read_transaction_present_q <= 1'b1;
        read_base_addr_q <= axi_manager.ar.addr;
        read_len_q <= axi_manager.ar.len;
        read_beat_index_q <= '0;
        read_id_q <= axi_manager.ar.id;
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
      write_transaction_present_q <= 1'b0;
      write_base_addr_q <= '0;
      write_beat_index_q <= '0;
      write_id_q <= '0;
      write_response_present_q <= 1'b0;
      write_address_handshake_count <= 0;
    end else begin
      if (axi_manager.aw_valid && axi_target.aw_ready) begin
        write_transaction_present_q <= 1'b1;
        write_base_addr_q <= axi_manager.aw.addr;
        write_beat_index_q <= '0;
        write_id_q <= axi_manager.aw.id;
        write_address_handshake_count <= write_address_handshake_count + 1;
      end

      if (axi_manager.w_valid && axi_target.w_ready) begin
        for (int unsigned byte_index = 0; byte_index < AXI4_STRB_WIDTH; byte_index++) begin
          if (axi_manager.w.strb[byte_index]) begin
            memory_byte_array[
                (int'(write_base_addr_q[15:0]) +
                 int'(write_beat_index_q) * AXI4_STRB_WIDTH + byte_index) %
                TEST_MEMORY_BYTES
            ] <= axi_manager.w.data[byte_index*8+:8];
          end
        end

        if (axi_manager.w.last) begin
          write_transaction_present_q <= 1'b0;
          write_response_present_q <= 1'b1;
        end else begin
          write_beat_index_q <= write_beat_index_q + 8'd1;
        end
      end

      if (axi_target.b_valid && axi_manager.b_ready) begin
        write_response_present_q <= 1'b0;
      end
    end
  end

  task automatic issue_memory_request(
      input phys_addr_t addr,
      input mem_cmd_e cmd,
      input core_data_t write_data,
      input core_byte_strobe_t byte_strobe,
      input mem_txn_id_t transaction_id,
      output core_data_t read_data
  );
    @(negedge clk);
    data_memory_req = '0;
    data_memory_req.addr = addr;
    data_memory_req.cmd = cmd;
    data_memory_req.size = TEST_WORD_SIZE;
    data_memory_req.write_data = write_data;
    data_memory_req.byte_strobe = byte_strobe;
    data_memory_req.transaction_id = transaction_id;
    data_memory_req_valid = 1'b1;

    while (!data_memory_req_ready) @(negedge clk);
    @(negedge clk);
    data_memory_req_valid = 1'b0;

    while (!data_memory_resp_valid) @(negedge clk);
    assert (!data_memory_resp.access_fault)
      else $fatal(1, "D-cache returned an unexpected access fault");
    assert (data_memory_resp.transaction_id == transaction_id)
      else $fatal(1, "D-cache response transaction ID mismatch");
    read_data = data_memory_resp.read_data;
    @(negedge clk);
  endtask

  task automatic clean_cache(input bit expect_clean_scan=0);
    int cycles;
    cycles=0;
    @(negedge clk);
    clean_req = 1'b1;
    while (!clean_done) begin
      @(negedge clk);
      cycles++;
    end
    if (expect_clean_scan)
      assert(cycles<=DCACHE_SET_COUNT)
        else $fatal(1,"clean scan inserted per-way/read wait cycles: %0d",cycles);
    assert (!clean_access_fault)
      else $fatal(1, "D-cache clean returned an unexpected access fault");
    @(negedge clk);
    clean_req = 1'b0;
  endtask

  // 连续发出store hit和同地址load。第二个请求必须与store响应同拍握手，下一拍
  // 返回的数据必须经过显式read-during-write bypass看到刚写入的值。
  task automatic issue_store_then_load_without_gap(
      input phys_addr_t addr,
      input core_data_t store_data,
      input core_byte_strobe_t byte_strobe,
      input int unsigned response_stall_cycles,
      output core_data_t load_data
  );
    @(negedge clk);
    data_memory_req = '0;
    data_memory_req.addr = addr;
    data_memory_req.cmd = MEM_CMD_STORE;
    data_memory_req.size = TEST_WORD_SIZE;
    data_memory_req.write_data = store_data;
    data_memory_req.byte_strobe = byte_strobe;
    data_memory_resp_ready = 1'b0;
    data_memory_req.transaction_id = mem_txn_id_t'(3);
    data_memory_req_valid = 1'b1;

    while (!data_memory_req_ready) @(negedge clk);
    @(negedge clk);
    assert (data_memory_resp_valid &&
            data_memory_resp.transaction_id == mem_txn_id_t'(3))
      else $fatal(1, "D-cache store hit did not respond before rollover lookup");

    data_memory_req_valid = 1'b0;
    repeat (response_stall_cycles) begin
      assert (!u_dut.data_write_valid)
        else $fatal(1, "D-cache wrote a store hit before its response handshake");
      @(negedge clk);
      assert (data_memory_resp_valid &&
              data_memory_resp.transaction_id == mem_txn_id_t'(3))
        else $fatal(1, "D-cache lost a backpressured store response");
    end
    data_memory_resp_ready = 1'b1;
    data_memory_req_valid = 1'b1;
    data_memory_req = '0;
    data_memory_req.addr = addr;
    data_memory_req.cmd = MEM_CMD_LOAD;
    data_memory_req.size = TEST_WORD_SIZE;
    data_memory_req.transaction_id = mem_txn_id_t'(4);
    #1;  // 等待 ready 随本拍解除的响应背压更新，再检查组合握手。
    assert (data_memory_req_ready)
      else $fatal(1, "D-cache inserted a fixed bubble after a store hit");

    @(negedge clk);
    data_memory_req_valid = 1'b0;
    assert (data_memory_resp_valid &&
            data_memory_resp.transaction_id == mem_txn_id_t'(4))
      else $fatal(1, "D-cache rollover load did not respond on the next cycle");
    assert (!data_memory_resp.access_fault)
      else $fatal(1, "D-cache rollover load returned an unexpected access fault");
    load_data = data_memory_resp.read_data;
    // 即使下一请求使用另一个地址，当前 load 及其字节旁路都必须保持到响应握手。
    data_memory_resp_ready = 1'b0;
    data_memory_req.addr = addr + phys_addr_t'(DCACHE_WORD_BYTES);
    repeat (4) begin
      @(negedge clk);
      assert (data_memory_resp_valid && data_memory_resp.read_data == load_data &&
              data_memory_resp.transaction_id == mem_txn_id_t'(4))
        else $fatal(1, "D-cache changed a stalled store-bypass response");
    end
    data_memory_resp_ready = 1'b1;
    @(negedge clk);
  endtask

  task automatic check_stalled_hit(input phys_addr_t addr, input core_data_t expected_data);
    @(negedge clk);
    data_memory_req = '0;
    data_memory_req.addr = addr;
    data_memory_req.cmd = MEM_CMD_LOAD;
    data_memory_req.size = TEST_WORD_SIZE;
    data_memory_req_valid = 1'b1;
    data_memory_resp_ready = 1'b0;
    while (!data_memory_req_ready) @(negedge clk);
    @(negedge clk);
    // 先改变无效 payload，再呈现被反压的新请求，二者都不能覆盖旧响应。
    data_memory_req_valid = 1'b0;
    repeat (6) begin
      data_memory_req.addr = data_memory_req.addr + phys_addr_t'(DCACHE_WORD_BYTES);
      @(negedge clk);
      assert (data_memory_resp_valid && data_memory_resp.read_data == expected_data)
        else $fatal(1, "D-cache stalled hit followed an unaccepted input address");
      assert (!data_memory_req_ready)
        else $fatal(1, "D-cache accepted a request over an unconsumed response");
    end
    data_memory_req.addr = addr;
    data_memory_req_valid = 1'b1;
    repeat (3) begin
      @(negedge clk);
      assert (!data_memory_req_ready && data_memory_resp_valid &&
              data_memory_resp.read_data == expected_data)
        else $fatal(1, "D-cache lost a hit while a second request waited");
    end
    data_memory_resp_ready = 1'b1;
    @(negedge clk);
    data_memory_req_valid = 1'b0;
    assert (data_memory_resp_valid && data_memory_resp.read_data == expected_data)
      else $fatal(1, "D-cache failed simultaneous response/request handoff");
    @(negedge clk);
  endtask

  initial begin
    core_data_t read_data;
    core_data_t original_a;
    core_data_t original_b;
    core_data_t original_c;
    core_data_t stored_a;
    core_data_t stored_c;
    int unsigned read_count_after_first_miss;

    clk = 1'b0;
    rst_ni = 1'b0;
    data_memory_req = '0;
    data_memory_req_valid = 1'b0;
    data_memory_resp_ready = 1'b1;
    clean_req = 1'b0;

    for (int unsigned byte_addr = 0; byte_addr < TEST_MEMORY_BYTES; byte_addr++) begin
      memory_byte_array[byte_addr] = 8'(byte_addr) ^ 8'h5a;
    end

    original_a = core_data_t'(read_memory_word(axi4_addr_t'(TEST_ADDR_A)));
    original_b = core_data_t'(read_memory_word(axi4_addr_t'(TEST_ADDR_B)));
    original_c = core_data_t'(read_memory_word(axi4_addr_t'(TEST_ADDR_C)));
    stored_a = core_data_t'(64'h8877_6655_4433_2211);
    stored_c = core_data_t'(64'h1020_3040_5060_7080);

    repeat (4) @(posedge clk);
    rst_ni = 1'b1;

    issue_memory_request(TEST_ADDR_A, MEM_CMD_LOAD, '0, '0, mem_txn_id_t'(1), read_data);
    assert (read_data == original_a)
      else $fatal(1, "D-cache refill returned incorrect data for line A");
    assert (read_address_handshake_count == 1)
      else $fatal(1, "first D-cache load did not issue exactly one AXI burst");

    read_count_after_first_miss = read_address_handshake_count;
    check_stalled_hit(TEST_ADDR_A, original_a);
    issue_memory_request(TEST_ADDR_A, MEM_CMD_LOAD, '0, '0, mem_txn_id_t'(2), read_data);
    assert (read_data == original_a)
      else $fatal(1, "D-cache hit returned incorrect data for line A");
    assert (read_address_handshake_count == read_count_after_first_miss)
      else $fatal(1, "D-cache hit incorrectly issued an AXI read");

    issue_store_then_load_without_gap(TEST_ADDR_A, stored_a, '1, 0, read_data);
    assert (write_address_handshake_count == 0)
      else $fatal(1, "write-back D-cache wrote a store hit to AXI immediately");
    assert (read_data == stored_a)
      else $fatal(1, "D-cache load did not observe a preceding store hit");

    // 响应背压期间不得提前写入；部分字节更新必须同时覆盖阵列写入和连续 load 的 bypass。
    issue_store_then_load_without_gap(TEST_ADDR_A, core_data_t'(32'haabb_ccdd),
                                     core_byte_strobe_t'(4'b0101), 3, read_data);
    stored_a[7:0] = 8'hdd;
    stored_a[23:16] = 8'hbb;
    assert (read_data == stored_a)
      else $fatal(1, "D-cache partial store bypass corrupted unwritten bytes");
    issue_memory_request(TEST_ADDR_A, MEM_CMD_LOAD, '0, '0, mem_txn_id_t'(4), read_data);
    assert (read_data == stored_a)
      else $fatal(1, "D-cache partial store did not update the array correctly");

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

    issue_memory_request(TEST_ADDR_C, MEM_CMD_STORE, stored_c, '1,
                         mem_txn_id_t'(7), read_data);
    clean_cache();
    assert (write_address_handshake_count == 2)
      else $fatal(1, "D-cache clean did not write back the remaining dirty line");
    assert (core_data_t'(read_memory_word(axi4_addr_t'(TEST_ADDR_C))) == stored_c)
      else $fatal(1, "D-cache clean did not update backing memory");
    clean_cache(1);
    // 填满各 set/way 的脏行，确认跳过 clean way 的扫描没有遗漏任何 dirty way。
    for (int way=0; way<DCACHE_WAY_COUNT; way++)
      for (int set_index=0; set_index<DCACHE_SET_COUNT; set_index++)
        issue_memory_request(phys_addr_t'(32'h80001000+way*DCACHE_SET_COUNT*DCACHE_LINE_BYTES+
                             set_index*DCACHE_LINE_BYTES), MEM_CMD_STORE,
                             core_data_t'(32'h77000000+way*DCACHE_SET_COUNT+set_index),'1,
                             mem_txn_id_t'(3),read_data);
    read_count_after_first_miss=write_address_handshake_count;
    clean_cache();
    assert(write_address_handshake_count==read_count_after_first_miss+DCACHE_SET_COUNT*DCACHE_WAY_COUNT)
      else $fatal(1,"clean scan skipped or repeated a dirty line");
    for (int way=0; way<DCACHE_WAY_COUNT; way++)
      for (int set_index=0; set_index<DCACHE_SET_COUNT; set_index++)
        assert(core_data_t'(read_memory_word(axi4_addr_t'(32'h80001000+
                   way*DCACHE_SET_COUNT*DCACHE_LINE_BYTES+set_index*DCACHE_LINE_BYTES)))==
                   core_data_t'(32'h77000000+way*DCACHE_SET_COUNT+set_index))
          else $fatal(1,"clean scan wrote wrong set/way data");
    clean_cache(1);

    $display("D-cache directed test passed: XLEN=%0d sets=%0d ways=%0d line=%0dB",
             XLEN, DCACHE_SET_COUNT, DCACHE_WAY_COUNT, DCACHE_LINE_BYTES);
    $finish;
  end

endmodule
