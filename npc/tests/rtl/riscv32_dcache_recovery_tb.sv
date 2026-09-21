module riscv32_dcache_recovery_tb;
  bit inject_error = 0, expected_fault = 0;
  int
      fault_mode = 2,
      b_delay = 0,
      r_delay = 0,
      partial_write = 0,
      store_miss = 0,
      response_stall = 0,
      r_error = 0;
  int b_countdown = 0, r_countdown = 0;
  import riscv32_pkg::*;
  import riscv32_addr_map_pkg::*;
  import riscv32_axi4_pkg::*;

  localparam int unsigned TEST_MEMORY_BYTES = 32'h0001_0000;
  localparam phys_addr_t TEST_ADDR_A = phys_addr_t'(32'h8000_0100);
  localparam phys_addr_t SAME_SET_ADDR_STRIDE = phys_addr_t'(DCACHE_SET_COUNT * DCACHE_LINE_BYTES);
  localparam phys_addr_t TEST_ADDR_B = TEST_ADDR_A + SAME_SET_ADDR_STRIDE;
  localparam phys_addr_t TEST_ADDR_C = TEST_ADDR_B + SAME_SET_ADDR_STRIDE;
  localparam mem_size_e TEST_WORD_SIZE = (CORE_DATA_WIDTH == 64) ? MEM_SIZE_DOUBLE : MEM_SIZE_WORD;

  logic                          clk;
  logic                          rst_ni;

  data_memory_req_t              data_memory_req;
  logic                          data_memory_req_valid;
  logic                          data_memory_req_ready;
  data_memory_resp_t             data_memory_resp;
  logic                          data_memory_resp_valid;
  logic                          data_memory_resp_ready;

  logic                          clean_req;
  logic                          clean_done;
  logic                          clean_access_fault;
  logic                          cache_busy;
  dcache_event_t                 dcache_event;

  axi4_manager_to_target_t       axi_manager;
  axi4_target_to_manager_t       axi_target;

  logic                    [7:0] memory_byte_array                        [TEST_MEMORY_BYTES];
  logic                          read_transaction_present_q;
  axi4_addr_t                    read_base_addr_q;
  logic                    [7:0] read_len_q;
  logic                    [7:0] read_beat_index_q;
  axi4_id_t                      read_id_q;

  logic                          write_transaction_present_q;
  axi4_addr_t                    write_base_addr_q;
  logic                    [7:0] write_beat_index_q;
  axi4_id_t                      write_id_q;
  logic                          write_response_present_q;

  int unsigned                   read_address_handshake_count;
  int unsigned                   write_address_handshake_count;
  logic                          dirty_miss_read_write_overlap_observed_q;
  int unsigned                   simultaneous_read_write_address_count;

  riscv32_dcache u_dut (
      .clk_i                   (clk),
      .rst_ni                  (rst_ni),
      .data_memory_req_i       (data_memory_req),
      .data_memory_req_valid_i (data_memory_req_valid),
      .data_memory_req_ready_o (data_memory_req_ready),
      .data_memory_resp_o      (data_memory_resp),
      .data_memory_resp_valid_o(data_memory_resp_valid),
      .data_memory_resp_ready_i(data_memory_resp_ready),
      .clean_req_i             (clean_req),
      .clean_done_o            (clean_done),
      .clean_access_fault_o    (clean_access_fault),
      .cache_busy_o            (cache_busy),
      .event_o                 (dcache_event),
      .axi_manager_o           (axi_manager),
      .axi_manager_i           (axi_target)
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
    axi_target.r_valid = read_transaction_present_q && r_countdown == 0;
    axi_target.r.data =
        read_memory_word(read_base_addr_q + axi4_addr_t'(read_beat_index_q * AXI4_STRB_WIDTH));
    axi_target.r.id = read_id_q;
    axi_target.r.resp = (r_error!=0 && inject_error && read_beat_index_q==1) ? AXI4_RESP_SLVERR : AXI4_RESP_OKAY;
    axi_target.r.last = read_beat_index_q == read_len_q;

    // WREADY只在AW完成后拉高，刻意验证D-cache adapter正确处理独立AW/W握手。
    axi_target.aw_ready = !write_transaction_present_q && !write_response_present_q;
    axi_target.w_ready = write_transaction_present_q;
    axi_target.b_valid = write_response_present_q && b_countdown == 0;
    axi_target.b.id = write_id_q;
    axi_target.b.resp = inject_error && fault_mode != 0 ? axi4_resp_e'(fault_mode) : AXI4_RESP_OKAY;
  end

  always_ff @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      r_countdown                  <= 0;
      read_transaction_present_q   <= 1'b0;
      read_base_addr_q             <= '0;
      read_len_q                   <= '0;
      read_beat_index_q            <= '0;
      read_id_q                    <= '0;
      read_address_handshake_count <= 0;
    end else begin
      if (r_countdown > 0) r_countdown <= r_countdown - 1;
      if (axi_manager.ar_valid && axi_target.ar_ready) begin
        r_countdown                  <= r_delay;
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

  // AR 可在 AW 的同一接收沿发出；该沿之前 target 的在途标志仍为 0。
  // 同时检查刚接收的 AW 和已经在 W/B 通道推进的事务，不能漏掉更早的交接。
  always_ff @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      dirty_miss_read_write_overlap_observed_q <= 1'b0;
      simultaneous_read_write_address_count    <= 0;
    end else if (axi_manager.ar_valid && axi_target.ar_ready) begin
      if (write_transaction_present_q || write_response_present_q ||
          (axi_manager.aw_valid && axi_target.aw_ready))
        dirty_miss_read_write_overlap_observed_q <= 1'b1;
      if (axi_manager.aw_valid && axi_target.aw_ready)
        simultaneous_read_write_address_count <= simultaneous_read_write_address_count + 1;
    end
  end

  always_ff @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      b_countdown                   <= 0;
      write_transaction_present_q   <= 1'b0;
      write_base_addr_q             <= '0;
      write_beat_index_q            <= '0;
      write_id_q                    <= '0;
      write_response_present_q      <= 1'b0;
      write_address_handshake_count <= 0;
    end else begin
      if (b_countdown > 0) b_countdown <= b_countdown - 1;
      if (axi_manager.aw_valid && axi_target.aw_ready) begin
        write_transaction_present_q   <= 1'b1;
        write_base_addr_q             <= axi_manager.aw.addr;
        write_beat_index_q            <= '0;
        write_id_q                    <= axi_manager.aw.id;
        write_address_handshake_count <= write_address_handshake_count + 1;
      end

      if (axi_manager.w_valid && axi_target.w_ready) begin
        for (int unsigned byte_index = 0; byte_index < AXI4_STRB_WIDTH; byte_index++) begin
          if (axi_manager.w.strb[byte_index] && (!inject_error || fault_mode==0 || (partial_write!=0 && write_beat_index_q<2))) begin
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
          b_countdown                 <= b_delay;
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
      input phys_addr_t addr, input mem_cmd_e cmd, input core_data_t write_data,
      input core_byte_strobe_t byte_strobe, input mem_txn_id_t transaction_id,
      output core_data_t read_data);
    @(negedge clk);
    data_memory_resp_ready         = 0;
    data_memory_req                = '0;
    data_memory_req.addr           = addr;
    data_memory_req.cmd            = cmd;
    data_memory_req.size           = TEST_WORD_SIZE;
    data_memory_req.write_data     = write_data;
    data_memory_req.byte_strobe    = byte_strobe;
    data_memory_req.transaction_id = transaction_id;
    data_memory_req_valid          = 1'b1;

    while (!data_memory_req_ready) @(negedge clk);
    @(negedge clk);
    data_memory_req_valid = 1'b0;

    while (!data_memory_resp_valid) @(negedge clk);
    assert (data_memory_resp.access_fault == expected_fault)
    else $fatal(1, "D-cache returned an unexpected access fault");
    assert (data_memory_resp.transaction_id == transaction_id)
    else $fatal(1, "D-cache response transaction ID mismatch");
    read_data = data_memory_resp.read_data;
    repeat (response_stall) begin
      @(negedge clk);
      assert(data_memory_resp_valid && data_memory_resp.access_fault==expected_fault &&
             data_memory_resp.read_data==read_data)
      else $fatal(1, "response changed under backpressure");
    end
    data_memory_resp_ready = 1;
    @(negedge clk);
  endtask



  initial begin
    core_data_t data;
    clk                    = 0;
    rst_ni                 = 0;
    data_memory_req        = '0;
    data_memory_req_valid  = 0;
    data_memory_resp_ready = 1;
    clean_req              = 0;
    for (int i = 0; i < TEST_MEMORY_BYTES; i++) memory_byte_array[i] = 0;
    if ($value$plusargs("fault=%d", fault_mode)) begin
    end
    if ($value$plusargs("b_delay=%d", b_delay)) begin
    end
    if ($value$plusargs("r_delay=%d", r_delay)) begin
    end
    if ($value$plusargs("partial=%d", partial_write)) begin
    end
    if ($value$plusargs("store=%d", store_miss)) begin
    end
    if ($value$plusargs("response_stall=%d", response_stall)) begin
    end
    if ($value$plusargs("r_error=%d", r_error)) begin
    end
    repeat (4) @(negedge clk);
    rst_ni = 1;
    // Fill every word with a distinct retired-store value, then exhaust the same set.
    for (int word_index = 0; word_index < DCACHE_WORDS_PER_LINE; word_index++)
    issue_memory_request(TEST_ADDR_A + phys_addr_t'(word_index * CORE_DATA_BYTE_COUNT),
                         MEM_CMD_STORE, core_data_t'(32'hdeadbe00 + word_index), '1, 0, data);
    issue_memory_request(TEST_ADDR_B, MEM_CMD_LOAD, 0, 0, 1, data);
    // A second failed replacement must not overwrite the protected victim context.
    for (int attempt = 0; attempt < 2; attempt++) begin
      inject_error   = (fault_mode != 0 || r_error != 0);
      expected_fault = inject_error;
      issue_memory_request(TEST_ADDR_C, store_miss != 0 ? MEM_CMD_STORE : MEM_CMD_LOAD,
                           core_data_t'(32'h01234567), '1, 2, data);
      inject_error   = 0;
      expected_fault = 0;
      for (int word_index = 0; word_index < DCACHE_WORDS_PER_LINE; word_index++) begin
        issue_memory_request(TEST_ADDR_A + phys_addr_t'(word_index * CORE_DATA_BYTE_COUNT),
                             MEM_CMD_LOAD, 0, 0, 3, data);
        assert (data == core_data_t'(32'hdeadbe00 + word_index))
        else $fatal(1, "old dirty word lost: word=%0d got=%h", word_index, data);
      end
    end
    // A later successful clean must still find the restored dirty line and save every word.
    @(negedge clk);
    clean_req = 1;
    while (!clean_done) @(negedge clk);
    assert (!clean_access_fault)
    else $fatal(1, "retry clean failed");
    @(negedge clk);
    clean_req = 0;
    for (int word_index = 0; word_index < DCACHE_WORDS_PER_LINE; word_index++)
    assert (read_memory_word(
        TEST_ADDR_A + phys_addr_t'(word_index * CORE_DATA_BYTE_COUNT)
    ) == core_data_t'(32'hdeadbe00 + word_index))
    else $fatal(1, "restored line was not dirty");
    $display("PASS dirty recovery fault=%0d R_error=%0d Bdelay=%0d Rdelay=%0d store=%0d",
             fault_mode, r_error, b_delay, r_delay, store_miss);
    $finish;
  end
  initial begin
    #1000000;
    $fatal(1, "cache recovery timeout");
  end
endmodule
