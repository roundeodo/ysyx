module riscv32_lsu_tb;
  import riscv32_pkg::*;
  import riscv32_addr_map_pkg::*;

  logic              clk;
  logic              rst_ni;

  lsu_req_t          lsu_req;
  logic              lsu_req_valid;
  logic              lsu_req_ready;
  logic              lsu_transaction_active;
  logic              lsu_pending_writes_rd;
  arch_reg_idx_t     lsu_pending_rd;

  data_memory_req_t  data_memory_req;
  logic              data_memory_req_valid;
  logic              data_memory_req_ready;

  data_memory_resp_t data_memory_resp;
  logic              data_memory_resp_valid;
  logic              data_memory_resp_ready;

  writeback_result_t lsu_writeback;
  logic              lsu_writeback_valid;
  logic              lsu_writeback_ready;

  riscv32_lsu u_lsu (
      .clk_i                   (clk),
      .rst_ni                  (rst_ni),
      .lsu_req_i               (lsu_req),
      .lsu_req_valid_i         (lsu_req_valid),
      .lsu_req_ready_o         (lsu_req_ready),
      .lsu_transaction_active_o(lsu_transaction_active),
      .lsu_pending_writes_rd_o (lsu_pending_writes_rd),
      .lsu_pending_rd_o        (lsu_pending_rd),
      .data_memory_req_o       (data_memory_req),
      .data_memory_req_valid_o (data_memory_req_valid),
      .data_memory_req_ready_i (data_memory_req_ready),
      .data_memory_resp_i      (data_memory_resp),
      .data_memory_resp_valid_i(data_memory_resp_valid),
      .data_memory_resp_ready_o(data_memory_resp_ready),
      .lsu_writeback_o         (lsu_writeback),
      .lsu_writeback_valid_o   (lsu_writeback_valid),
      .lsu_writeback_ready_i   (lsu_writeback_ready)
  );

  always #5 clk = ~clk;

  function automatic lsu_req_t make_memory_request(
      input mem_cmd_e command, input mem_size_e access_size, input logic unsigned_load,
      input effective_addr_t effective_addr, input xlen_data_t store_data);
    lsu_req_t request;
    request                            = '0;
    request.uop.fu_type                = FU_LSU;
    request.uop.mem_ctrl.cmd           = command;
    request.uop.mem_ctrl.size          = access_size;
    request.uop.mem_ctrl.unsigned_load = unsigned_load;
    request.uop.writes_rd              = command == MEM_CMD_LOAD;
    request.next_pc                    = program_counter_t'(32'h8000_0104);
    request.effective_addr             = effective_addr;
    request.store_data                 = store_data;
    return request;
  endfunction

  // 普通访存必须先在LSU入口握手并锁存，随后才允许从寄存后的上下文发往存储层。
  // 该任务同时检查不存在EXU到存储系统的同拍组合旁路。
  task automatic accept_registered_memory_request(input lsu_req_t request);
    @(negedge clk);
    lsu_req               = request;
    lsu_req_valid         = 1'b1;
    data_memory_req_ready = 1'b0;
    #1;
    assert (lsu_req_ready && data_memory_req_valid)
    else $fatal(1, "LSU did not bypass an idle request");

    @(posedge clk);
    #1;
    lsu_req_valid = 1'b0;

    @(negedge clk);
    #1;
    assert (data_memory_req_valid)
    else $fatal(1, "LSU did not retain a blocked memory request");
    data_memory_req_ready = 1'b1;
  endtask

  // 异常和未对齐请求同样必须先经过入口寄存器，不能为了减少一拍而重新建立
  // execute_packet到writeback的组合旁路。
  task automatic accept_registered_local_completion(input lsu_req_t request);
    @(negedge clk);
    lsu_req               = request;
    lsu_req_valid         = 1'b1;
    data_memory_req_ready = 1'b1;
    lsu_writeback_ready   = 1'b1;
    #1;
    assert (lsu_req_ready && !data_memory_req_valid && !lsu_writeback_valid)
    else $fatal(1, "LSU produced outputs before registering a local completion request");

    @(posedge clk);
    #1;
    lsu_req_valid = 1'b0;

    @(negedge clk);
    #1;
    assert (!lsu_req_ready && !data_memory_req_valid && lsu_writeback_valid)
    else $fatal(1, "LSU did not produce the registered local completion");
  endtask

  task automatic check_load(input mem_size_e access_size, input logic unsigned_load,
                            input effective_addr_t effective_addr,
                            input core_data_t returned_memory_data,
                            input xlen_data_t expected_result);
    accept_registered_memory_request(
        make_memory_request(MEM_CMD_LOAD, access_size, unsigned_load, effective_addr, '0)
    );
    assert ((data_memory_req.addr == phys_addr_t'(effective_addr)) &&
            (data_memory_req.cmd == MEM_CMD_LOAD) &&
            (data_memory_req.size == access_size) &&
            (data_memory_req.byte_strobe == '0))
    else $fatal(1, "LSU load request payload mismatch: XLEN=%0d size=%0d", XLEN, access_size);

    @(posedge clk);
    #1;
    data_memory_req_ready = 1'b0;

    @(negedge clk);
    data_memory_resp                = '0;
    data_memory_resp.read_data      = returned_memory_data;
    data_memory_resp.transaction_id = '0;
    data_memory_resp_valid          = 1'b1;
    lsu_writeback_ready             = 1'b1;
    #1;
    assert (data_memory_resp_ready && lsu_writeback_valid)
    else $fatal(1, "LSU did not return load result: XLEN=%0d size=%0d", XLEN, access_size);
    assert (lsu_writeback.result == expected_result)
    else
      $fatal(
          1,
          "LSU load result mismatch: XLEN=%0d size=%0d addr=%h expected=%h actual=%h",
          XLEN,
          access_size,
          effective_addr,
          expected_result,
          lsu_writeback.result
      );

    @(posedge clk);
    #1;
    data_memory_resp_valid = 1'b0;
  endtask

  task automatic check_store(input mem_size_e access_size, input effective_addr_t effective_addr,
                             input xlen_data_t store_data, input core_data_t expected_write_data,
                             input core_byte_strobe_t expected_byte_strobe);
    accept_registered_memory_request(
        make_memory_request(MEM_CMD_STORE, access_size, 1'b0, effective_addr, store_data)
    );
    assert ((data_memory_req.addr == phys_addr_t'(effective_addr)) &&
            (data_memory_req.cmd == MEM_CMD_STORE) &&
            (data_memory_req.size == access_size) &&
            (data_memory_req.write_data == expected_write_data) &&
            (data_memory_req.byte_strobe == expected_byte_strobe))
    else
      $fatal(
          1,
          "LSU store payload mismatch: XLEN=%0d size=%0d data=%h/%h strobe=%h/%h",
          XLEN,
          access_size,
          data_memory_req.write_data,
          expected_write_data,
          data_memory_req.byte_strobe,
          expected_byte_strobe
      );

    @(posedge clk);
    #1;
    data_memory_req_ready = 1'b0;

    @(negedge clk);
    data_memory_resp       = '0;
    data_memory_resp_valid = 1'b1;
    lsu_writeback_ready    = 1'b1;
    #1;
    assert (data_memory_resp_ready && lsu_writeback_valid)
    else $fatal(1, "LSU did not complete store: XLEN=%0d size=%0d", XLEN, access_size);
    assert ((lsu_writeback.memory_wdata == expected_write_data) &&
            (lsu_writeback.memory_wmask == expected_byte_strobe) &&
            !lsu_writeback.uop.exception_valid)
    else $fatal(1, "LSU store writeback mismatch: XLEN=%0d size=%0d", XLEN, access_size);

    @(posedge clk);
    #1;
    data_memory_resp_valid = 1'b0;
  endtask

  task automatic check_misaligned_access(input mem_cmd_e command, input mem_size_e access_size,
                                         input effective_addr_t effective_addr,
                                         input exception_cause_e expected_cause);
    accept_registered_local_completion(make_memory_request(
        command, access_size, 1'b0, effective_addr, xlen_data_t'(64'h0123_4567_89ab_cdef)
    ));
    assert (lsu_writeback_valid && !data_memory_req_valid)
    else $fatal(1, "Misaligned access escaped to memory: XLEN=%0d size=%0d", XLEN, access_size);
    assert (lsu_writeback.uop.exception_valid &&
            (lsu_writeback.uop.exception_cause == expected_cause) &&
            (lsu_writeback.uop.exception_tval == xlen_data_t'(effective_addr)))
    else $fatal(1, "Misaligned exception mismatch: XLEN=%0d size=%0d", XLEN, access_size);

    @(posedge clk);
    #1;
    lsu_req_valid = 1'b0;
  endtask

  task automatic check_preexisting_exception_is_preserved;
    lsu_req_t exception_request;

    exception_request                 = make_memory_request(
        MEM_CMD_LOAD, MEM_SIZE_WORD, 1'b0, effective_addr_t'(32'h8000_0000), '0
    );
    exception_request.uop.exception_valid = 1'b1;
    exception_request.uop.exception_cause = EXC_ILLEGAL_INSTRUCTION;
    exception_request.uop.exception_tval  = xlen_data_t'(32'hffff_ffff);
    accept_registered_local_completion(exception_request);

    assert (lsu_writeback_valid && !data_memory_req_valid)
      else $fatal(1, "LSU issued memory traffic for an instruction with an older exception");
    assert (lsu_writeback.uop.exception_valid &&
            (lsu_writeback.uop.exception_cause == EXC_ILLEGAL_INSTRUCTION) &&
            (lsu_writeback.uop.exception_tval == xlen_data_t'(32'hffff_ffff)))
      else $fatal(1, "LSU overwrote an older exception");

    @(posedge clk);
    #1;
    lsu_req_valid = 1'b0;
  endtask

  task automatic check_access_fault(
      input mem_cmd_e command,
      input exception_cause_e expected_cause
  );
    accept_registered_memory_request(make_memory_request(
        command, MEM_SIZE_WORD, 1'b0, effective_addr_t'(32'h8000_0040),
        xlen_data_t'(32'h1234_5678)
    ));

    @(posedge clk);
    #1;
    data_memory_req_ready = 1'b0;

    @(negedge clk);
    data_memory_resp                = '0;
    data_memory_resp.access_fault   = 1'b1;
    data_memory_resp.transaction_id = '0;
    data_memory_resp_valid          = 1'b1;
    lsu_writeback_ready             = 1'b1;
    #1;
    assert (data_memory_resp_ready && lsu_writeback_valid &&
            lsu_writeback.uop.exception_valid &&
            (lsu_writeback.uop.exception_cause == expected_cause) &&
            (lsu_writeback.uop.exception_tval == xlen_data_t'(32'h8000_0040)) &&
            !lsu_writeback.uop.writes_rd)
      else $fatal(1, "LSU access-fault completion mismatch: command=%0d", command);

    @(posedge clk);
    #1;
    data_memory_resp_valid = 1'b0;
  endtask

  task automatic check_response_backpressure;
    writeback_result_t held_writeback;

    @(negedge clk);
    lsu_req               = make_memory_request(MEM_CMD_LOAD, MEM_SIZE_WORD, 1'b0,
                            effective_addr_t'(32'h8000_0000), '0);
    lsu_req_valid         = 1'b1;
    data_memory_req_ready = 1'b0;
    lsu_writeback_ready   = 1'b1;
    #1;
    assert (lsu_req_ready && data_memory_req_valid)
    else $fatal(1, "LSU idle request did not reach the blocked memory port");

    @(posedge clk);
    #1;
    lsu_req_valid = 1'b0;

    @(negedge clk);
    #1;
    assert (!lsu_req_ready && data_memory_req_valid)
    else $fatal(1, "LSU did not retain blocked memory request");
    data_memory_req_ready = 1'b1;

    @(posedge clk);
    #1;
    data_memory_req_ready = 1'b0;

    @(negedge clk);
    data_memory_resp           = '0;
    data_memory_resp.read_data = core_data_t'(32'h8000_0001);
    data_memory_resp_valid     = 1'b1;
    lsu_writeback_ready        = 1'b0;
    #1;
    assert (!data_memory_resp_ready && lsu_writeback_valid)
    else $fatal(1, "LSU did not propagate writeback backpressure to memory response");
    held_writeback = lsu_writeback;

    @(posedge clk);
    #1;

    @(negedge clk);
    #1;
    assert (!data_memory_resp_ready && lsu_writeback_valid && (lsu_writeback == held_writeback))
    else $fatal(1, "LSU response changed under propagated downstream backpressure");
    lsu_writeback_ready = 1'b1;
    #1;
    assert (data_memory_resp_ready)
    else $fatal(1, "LSU did not release memory response after writeback became ready");

    @(posedge clk);
    #1;
    data_memory_resp_valid = 1'b0;
  endtask

  task automatic check_consecutive_load_serialization;
    lsu_req_t first_load;
    lsu_req_t second_load;

    first_load        = make_memory_request(MEM_CMD_LOAD, MEM_SIZE_WORD, 1'b0,
                                            effective_addr_t'(32'h8000_0100), '0);
    first_load.uop.rd = arch_reg_idx_t'(6);
    second_load       = make_memory_request(MEM_CMD_LOAD, MEM_SIZE_WORD, 1'b0,
                                            effective_addr_t'(32'h8000_0200), '0);
    second_load.uop.rd = arch_reg_idx_t'(7);

    accept_registered_memory_request(first_load);

    @(posedge clk);
    #1;
    assert (lsu_transaction_active && lsu_pending_writes_rd &&
            (lsu_pending_rd == arch_reg_idx_t'(6)))
    else $fatal(1, "LSU did not retain the first rollover load identity");

    @(negedge clk);
    lsu_req                       = second_load;
    lsu_req_valid                 = 1'b1;
    data_memory_resp              = '0;
    data_memory_resp.read_data    = core_data_t'(32'h1111_1111);
    data_memory_resp_valid        = 1'b1;
    lsu_writeback_ready           = 1'b1;
    data_memory_req_ready         = 1'b0;
    #1;
    assert (data_memory_resp_ready && lsu_writeback_valid && lsu_req_ready)
    else $fatal(1, "LSU failed same-cycle completion/request handoff");
    assert ((lsu_writeback.uop.rd == arch_reg_idx_t'(6)) &&
            (lsu_writeback.result == xlen_data_t'(32'h1111_1111)))
    else $fatal(1, "LSU mixed the older response with the younger request payload");

    @(posedge clk);
    #1;
    data_memory_resp_valid = 1'b0;
    lsu_req_valid = 1'b0;
    @(negedge clk);
    #1;
    assert (!lsu_req_ready && data_memory_req_valid &&
            data_memory_req.addr == phys_addr_t'(32'h8000_0200) &&
            lsu_pending_rd == arch_reg_idx_t'(7))
    else $fatal(1, "LSU did not preserve the rollover request under backpressure");
    data_memory_req_ready = 1'b1;
    @(posedge clk);
    #1;
    data_memory_req_ready         = 1'b0;

    @(negedge clk);
    data_memory_resp              = '0;
    data_memory_resp.read_data    = core_data_t'(32'h2222_2222);
    data_memory_resp_valid        = 1'b1;
    #1;
    assert (data_memory_resp_ready && lsu_writeback_valid &&
            (lsu_writeback.uop.rd == arch_reg_idx_t'(7)) &&
            (lsu_writeback.result == xlen_data_t'(32'h2222_2222)))
    else $fatal(1, "LSU did not complete the serialized younger load");

    @(posedge clk);
    #1;
    data_memory_resp_valid = 1'b0;
  endtask

  task automatic check_direct_rollover;
    @(negedge clk);
    lsu_req = make_memory_request(MEM_CMD_LOAD, MEM_SIZE_BYTE, 1'b0,
        effective_addr_t'(32'h80000003), '0);
    lsu_req.uop.rd = arch_reg_idx_t'(11);
    lsu_req_valid = 1'b1;
    data_memory_req_ready = 1'b1;
    #1;
    assert (lsu_req_ready && data_memory_req_valid)
      else $fatal(1, "idle ready memory path did not bypass request storage");
    @(posedge clk);
    @(negedge clk);
    lsu_req = make_memory_request(MEM_CMD_STORE, MEM_SIZE_BYTE, 1'b0,
        effective_addr_t'(32'h80000005), xlen_data_t'(8'h55));
    data_memory_resp = '0;
    data_memory_resp.read_data = core_data_t'(32'haa000000);
    data_memory_resp_valid = 1'b1;
    lsu_writeback_ready = 1'b0;
    #1;
    assert (!lsu_req_ready && !data_memory_req_valid && lsu_writeback_valid)
      else $fatal(1, "rollover ignored writeback backpressure");
    @(posedge clk);
    @(negedge clk);
    lsu_writeback_ready = 1'b1;
    #1;
    assert (lsu_req_ready && data_memory_req_valid && data_memory_resp_ready &&
            data_memory_req.addr == 32'h80000005 && data_memory_req.cmd == MEM_CMD_STORE &&
            lsu_writeback.uop.rd == 11 && lsu_writeback.memory_addr == 32'h80000003 &&
            lsu_writeback.result == xlen_data_t'(-86))
      else $fatal(1, "same-cycle load completion and byte store mixed contexts");
    @(posedge clk);
    @(negedge clk);
    lsu_req_valid = 1'b0;
    data_memory_resp_valid = 1'b0;
    @(negedge clk);
    data_memory_resp_valid = 1'b1;
    #1;
    assert (lsu_writeback_valid && lsu_writeback.memory_addr == 32'h80000005 &&
            !lsu_writeback.uop.writes_rd && lsu_writeback.memory_wmask ==
            (core_byte_strobe_t'(1) << (5 % CORE_DATA_BYTE_COUNT)))
      else $fatal(1, "directly dispatched store context was lost");
    @(posedge clk);
    @(negedge clk);
    data_memory_resp_valid = 1'b0;
  endtask

  initial begin
    clk                    = 1'b0;
    rst_ni                 = 1'b0;
    lsu_req                = '0;
    lsu_req_valid          = 1'b0;
    data_memory_req_ready  = 1'b0;
    data_memory_resp       = '0;
    data_memory_resp_valid = 1'b0;
    lsu_writeback_ready    = 1'b1;

    repeat (2) @(posedge clk);
    @(negedge clk);
    rst_ni = 1'b1;

    check_load(MEM_SIZE_BYTE, 1'b0, effective_addr_t'(32'h8000_0003), core_data_t'(32'h80aa_5500),
               xlen_data_t'(-128));
    check_load(MEM_SIZE_BYTE, 1'b1, effective_addr_t'(32'h8000_0003), core_data_t'(32'h80aa_5500),
               xlen_data_t'(8'h80));
    check_load(MEM_SIZE_HALF, 1'b0, effective_addr_t'(32'h8000_0002), core_data_t'(32'h8001_5500),
               xlen_data_t'(-32767));
    check_load(MEM_SIZE_HALF, 1'b1, effective_addr_t'(32'h8000_0002), core_data_t'(32'h8001_5500),
               xlen_data_t'(16'h8001));
    check_load(MEM_SIZE_WORD, 1'b0, effective_addr_t'(32'h8000_0000), core_data_t'(32'h8000_0001), {
               {(XLEN - 32) {1'b1}}, 32'h8000_0001});

    check_store(MEM_SIZE_BYTE, effective_addr_t'(32'h8000_0003), xlen_data_t'(8'haa),
                core_data_t'(32'haa00_0000), core_byte_strobe_t'(4'b1000));
    check_store(MEM_SIZE_HALF, effective_addr_t'(32'h8000_0002), xlen_data_t'(16'hcdef),
                core_data_t'(32'hcdef_0000), core_byte_strobe_t'(4'b1100));
    check_store(MEM_SIZE_WORD, effective_addr_t'(32'h8000_0000), xlen_data_t'(32'h89ab_cdef),
                core_data_t'(32'h89ab_cdef), core_byte_strobe_t'(4'b1111));

    check_misaligned_access(MEM_CMD_LOAD, MEM_SIZE_HALF, effective_addr_t'(32'h8000_0001),
                            EXC_LOAD_ADDR_MISALIGNED);
    check_misaligned_access(MEM_CMD_STORE, MEM_SIZE_WORD, effective_addr_t'(32'h8000_0002),
                            EXC_STORE_ADDR_MISALIGNED);
    check_preexisting_exception_is_preserved();
    check_access_fault(MEM_CMD_LOAD, EXC_LOAD_ACCESS_FAULT);
    check_access_fault(MEM_CMD_STORE, EXC_STORE_ACCESS_FAULT);

`ifdef YSYX_RV64_SEQUENTIAL
    check_load(MEM_SIZE_WORD, 1'b1, effective_addr_t'(32'h8000_0004), 64'h8000_0001_0123_4567,
               64'h0000_0000_8000_0001);
    check_load(MEM_SIZE_DOUBLE, 1'b0, effective_addr_t'(32'h8000_0000), 64'hfedc_ba98_7654_3210,
               64'hfedc_ba98_7654_3210);

    check_store(MEM_SIZE_WORD, effective_addr_t'(32'h8000_0004), 64'h0123_4567_89ab_cdef,
                64'h89ab_cdef_0000_0000, 8'b1111_0000);
    check_store(MEM_SIZE_DOUBLE, effective_addr_t'(32'h8000_0000), 64'h0123_4567_89ab_cdef,
                64'h0123_4567_89ab_cdef, 8'hff);

    check_misaligned_access(MEM_CMD_LOAD, MEM_SIZE_DOUBLE, effective_addr_t'(32'h8000_0004),
                            EXC_LOAD_ADDR_MISALIGNED);
    check_misaligned_access(MEM_CMD_STORE, MEM_SIZE_DOUBLE, effective_addr_t'(32'h8000_0004),
                            EXC_STORE_ADDR_MISALIGNED);
`endif

    check_response_backpressure();
    check_consecutive_load_serialization();
    check_direct_rollover();

    $display("LSU directed memory test passed for XLEN=%0d", XLEN);
    $finish;
  end

endmodule : riscv32_lsu_tb
