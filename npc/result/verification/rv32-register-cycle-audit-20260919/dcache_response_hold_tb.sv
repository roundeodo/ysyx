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
    @(negedge clk);
  endtask

  // Audit only: invalid request payload may change while an older response is stalled.
  initial begin
    core_data_t read_data;
    core_data_t held_data;
    int change_address;
    clk = 0;
    rst_ni = 0;
    data_memory_req = '0;
    data_memory_req_valid = 0;
    data_memory_resp_ready = 1;
    clean_req = 0;
    change_address = 0;
    void'($value$plusargs("change_address=%d", change_address));
    for (int unsigned addr = 0; addr < TEST_MEMORY_BYTES; addr++)
      memory_byte_array[addr] = 8'(addr) ^ 8'h5a;
    repeat (4) @(negedge clk);
    rst_ni = 1;
    issue_memory_request(TEST_ADDR_A, MEM_CMD_LOAD, '0, '0, mem_txn_id_t'(1), read_data);
    @(negedge clk);
    data_memory_req = '0;
    data_memory_req.addr = TEST_ADDR_A;
    data_memory_req.cmd = MEM_CMD_LOAD;
    data_memory_req.size = TEST_WORD_SIZE;
    data_memory_req.transaction_id = mem_txn_id_t'(2);
    data_memory_req_valid = 1;
    data_memory_resp_ready = 0;
    #1;
    assert (data_memory_req_ready) else $fatal(1,"audit setup: cache not ready");
    @(negedge clk);
    assert (data_memory_resp_valid) else $fatal(1,"audit setup: expected hit");
    held_data = data_memory_resp.read_data;
    data_memory_req_valid = 0;
    if (change_address) data_memory_req.addr = TEST_ADDR_A + phys_addr_t'(CORE_DATA_BYTE_COUNT);
    @(negedge clk);
    $display("AUDIT change_address=%0d req_valid=%b resp_ready=%b expected=%h observed=%h valid=%b",
      change_address, data_memory_req_valid, data_memory_resp_ready,
      held_data, data_memory_resp.read_data, data_memory_resp_valid);
    assert (data_memory_resp_valid && data_memory_resp.read_data == held_data)
      else $fatal(1,"AUDIT_RESPONSE_NOT_STABLE");
    $display("PASS audit held response");
    $finish;
  end
endmodule
