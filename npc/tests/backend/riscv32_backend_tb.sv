// 老除法阻挡退休，年轻异常后已有投机 load；恢复时排空迟到响应，并复用 ROB 槽。
module riscv32_backend_tb;
  import riscv32_pkg::*;
  bit clk = 0;
  always #5 clk = !clk;
  logic rst = 0, decoded_valid = 0, decoded_ready, flush;
  decoded_uop_t decoded;
  xlen_data_t rs1, rs2;
  lsu_req_t request, pending_request;
  lsu_req_t request_array[LSU_ENTRIES];
  bit occupied[LSU_ENTRIES];
  int timers[LSU_ENTRIES];
  mem_txn_id_t allocate_id, return_id;
  logic request_valid, request_ready, response_valid, response_ready;
  writeback_result_t response, head;
  logic head_valid, pending = 0;
  int delay_cycles = 100, countdown = 0, requests = 0, discards = 0, retired = 0, fault_seen = 0;
  int first_fault = 0, response_on_flush = 0;
  logic finish_seen = 0;
  riscv32_backend dut (
      .clk_i                      (clk),
      .rst_ni                     (rst),
      .issue_uop_i                  (decoded),
      .issue_valid_i            (decoded_valid),
      .issue_ready_o            (decoded_ready),
      .rs1_i                      (rs1),
      .rs2_i                      (rs2),
      .csr_data_i                 ('0),
      .csr_illegal_i              (1'b0),
      .issue_hold_i              (1'b0),
      .maintenance_i              (1'b0),
      .flush_i                    (flush),
      .lsu_req_o                  (request),
      .lsu_valid_o                (request_valid),
      .lsu_ready_i                (request_ready),
      .lsu_req_id_i (allocate_id), .lsu_result_id_i (return_id),
      .lsu_result_i               (response),
      .lsu_result_valid_i         (response_valid),
      .lsu_result_ready_o         (response_ready),
      .head_o                     (head),
      .head_valid_o               (head_valid),
      .head_ready_i               (1'b1),
      .resolved_o                 (),
      .resolved_valid_o           (),
      .sequential_redirect_o      (),
      .sequential_redirect_valid_o(),
      .execute_packet_o           (),
      .execute_valid_o            (),
      .issue_allowed_o            (),
      .execute_ready_o            (),
      .busy_o                     (),
      .raw_o                      (),
      .serializing_o              (),
      .structural_o               ()
  );
  assign flush          = head_valid && head.uop.exception_valid;
  always_comb begin
    request_ready = 0;
    allocate_id = 0;
    response_valid = 0;
    return_id = 0;
    pending = 0;
    for (int slot = LSU_ENTRIES-1; slot >= 0; slot--) begin
      if (occupied[slot]) pending = 1;
      if (occupied[slot] && timers[slot] == 0) begin
        response_valid = 1; return_id = mem_txn_id_t'(slot);
      end
    end
    for (int slot = LSU_ENTRIES-1; slot >= 0; slot--) begin
      if (!occupied[slot] || (response_valid && response_ready && int'(return_id) == slot)) begin
        request_ready = 1; allocate_id = mem_txn_id_t'(slot);
      end
    end
    pending_request = request_array[return_id];
  end
  always_comb begin
    response              = '0;
    response.uop          = pending_request.uop;
    response.next_pc      = pending_request.next_pc;
    response.result       = 32'h12345678;
    response.memory_addr  = pending_request.effective_addr;
    response.memory_rdata = 32'h12345678;
    if (pending_request.uop.pc == 32'h108 && first_fault != 0) begin
      response.uop.exception_valid = 1;
      response.uop.exception_cause = EXC_LOAD_ACCESS_FAULT;
      response.uop.exception_tval  = pending_request.effective_addr;
    end
  end
  always @(posedge clk) begin
    if (rst) begin
      for (int slot = 0; slot < LSU_ENTRIES; slot++)
        if (occupied[slot] && timers[slot] > 0) timers[slot] <= timers[slot] - 1;
      if (response_valid && response_ready) begin
        occupied[return_id] <= 0;
        if (dut.lsu_discard_vector_q[return_id]) discards++;
        if (flush) response_on_flush++;
      end
      if (request_valid && request_ready) begin
        assert (request.uop.mem_ctrl.cmd == MEM_CMD_LOAD)
        else $fatal(1, "younger store/MMIO escaped");
        occupied[allocate_id] <= 1;
        request_array[allocate_id] <= request;
        requests++;
        timers[allocate_id] <= request.uop.pc == 'h108 ? delay_cycles :
            (request.uop.pc == 'h10c ? delay_cycles + 12 : 3);
      end
      if (head_valid) begin
        retired++;
        assert (head.uop.pc != 32'h108 && head.uop.pc != 32'h10c)
        else $fatal(1, "canceled instruction retired");
        if (head.uop.pc == 32'h100)
          assert (head.result == 32'h06f5e4d3)
          else $fatal(1, "older divide lost");
        if (flush) begin
          assert (head.uop.pc == 32'h104 && head.uop.exception_cause == EXC_ILLEGAL_INSTRUCTION);
          fault_seen++;
        end
        if (head.uop.pc == 32'h300) begin
          assert (!head.uop.exception_valid && head.result == 32'h12345678)
          else $fatal(1, "late response corrupted reused identity");
          finish_seen = 1;
        end
      end
    end
  end
  task automatic send(input decoded_uop_t instruction, input xlen_data_t a, b);
    @(negedge clk);
    decoded       = instruction;
    rs1           = a;
    rs2           = b;
    decoded_valid = 1;
    do begin
      @(posedge clk);
    end while (!decoded_ready);
    @(negedge clk);
    decoded_valid = 0;
  endtask
  decoded_uop_t operation;
  initial begin
    void'($value$plusargs("delay=%d", delay_cycles));
    void'($value$plusargs("fault=%d", first_fault));
    decoded = '0;
    rs1     = 0;
    rs2     = 0;
    repeat (3) @(negedge clk);
    rst                 = 1;
    operation           = '0;
    operation.pc        = 'h100;
    operation.fu_type   = FU_MULDIV;
    operation.muldiv_op = MD_DIVU;
    operation.uses_rs1  = 1;
    operation.uses_rs2  = 1;
    operation.rs1       = 1;
    operation.rs2       = 2;
    operation.writes_rd = 1;
    operation.rd        = 3;
    send(operation, 'h76543210, 17);
    operation                 = '0;
    operation.pc              = 'h104;
    operation.exception_valid = 1;
    operation.exception_cause = EXC_ILLEGAL_INSTRUCTION;
    send(operation, 0, 0);
    operation               = '0;
    operation.pc            = 'h108;
    operation.fu_type       = FU_LSU;
    operation.mem_ctrl.cmd  = MEM_CMD_LOAD;
    operation.mem_ctrl.size = MEM_SIZE_WORD;
    operation.uses_rs1      = 1;
    operation.rs1           = 1;
    operation.writes_rd     = 1;
    operation.rd            = 4;
    send(operation, 'h80001000, 0);
    operation.pc           = 'h10c;
    operation.mem_ctrl.cmd = LSU_ENTRIES == 1 ? MEM_CMD_STORE : MEM_CMD_LOAD;
    operation.writes_rd    = LSU_ENTRIES > 1;
    send(operation, LSU_ENTRIES == 1 ? 'h10000000 : 'h80001040, 0);
    wait (fault_seen == 1);
    for (int i = 0; i < 8; i++) begin
      operation                           = '0;
      operation.pc                        = 32'h200 + 32'(i * 4);
      operation.fu_type                   = FU_INT;
      operation.int_ctrl.op               = ALU_ADD;
      operation.int_ctrl.operand_a_select = OPA_ZERO;
      operation.int_ctrl.operand_b_select = OPB_IMM;
      operation.imm                       = 32'(i + 100);
      operation.writes_rd                 = 1;
      operation.rd                        = arch_reg_idx_t'(i + 10);
      send(operation, 0, 0);
    end
    operation               = '0;
    operation.pc            = 'h300;
    operation.fu_type       = FU_LSU;
    operation.mem_ctrl.cmd  = MEM_CMD_LOAD;
    operation.mem_ctrl.size = MEM_SIZE_WORD;
    operation.uses_rs1      = 1;
    operation.rs1           = 1;
    operation.writes_rd     = 1;
    operation.rd            = 4;
    send(operation, 'h80002000, 0);
    wait (finish_seen);
    while (pending) @(negedge clk);
    @(negedge clk);
    assert (requests == LSU_ENTRIES + 1 && fault_seen == 1 && retired == 11);
    if (delay_cycles >= 100)
      assert (discards == LSU_ENTRIES)
      else $fatal(1, "late-response case not exercised");
    $display(
        "PASS backend delay=%0d fault=%0d requests=%0d discarded=%0d simultaneous_flush_response=%0d retired=%0d",
        delay_cycles, first_fault, requests, discards, response_on_flush, retired);
    $finish;
  end
  initial begin
    #30000;
    $fatal(1, "timeout");
  end
endmodule
