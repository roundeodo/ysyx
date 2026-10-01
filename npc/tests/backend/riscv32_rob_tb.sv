module riscv32_rob_tb;
  import riscv32_pkg::*;
  bit clk = 0;
  always #5 clk = !clk;
  logic rst = 0, flush, allocation_handshake, ready, recover, head_valid, head_ready, empty;
  decoded_uop_t uop;
  backend_tag_t tail, head_tag, recovery_tag;
  logic [BACKEND_ENTRIES-1:0] cancel_vector;
  logic [BACKEND_TAG_W:0] count;
  backend_completion_t completion_array[BACKEND_PORTS];
  execute_producer_t producer_array[BACKEND_ENTRIES];
  writeback_result_t head;
  riscv32_rob dut (
      .clk_i           (clk),
      .rst_ni          (rst),
      .flush_i         (flush),
      .allocate_uop_i  (uop),
      .allocate_valid_i(allocation_handshake),
      .allocate_ready_o(ready),
      .allocate_tag_o  (tail),
      .alu_i           (completion_array[0]),
      .multiply_i      (completion_array[1]),
      .divide_i        (completion_array[2]),
      .memory_i        (completion_array[3]),
      .recover_i       (recover),
      .recover_tag_i   (recovery_tag),
      .cancel_vector_o (cancel_vector),
      .producer_array_o(producer_array),
      .head_o          (head),
      .head_valid_o    (head_valid),
      .head_ready_i    (head_ready),
      .head_tag_o      (head_tag),
      .empty_o         (empty),
      .count_o         (count)
  );
  typedef struct packed {
    backend_tag_t tag;
    logic [31:0] pc, value;
    bit done, fault;
  } reference_entry_t;
  reference_entry_t queue[$], item;
  int seed = 20260928, sequence_number = 0, completes, simultaneous = 0;
  int popped = 0, recoveries = 0, exchanges = 0, selected, survivor_count;
  bit expected_valid, retire_handshake, input_accept;
  logic [31:0] expected_value;
  bit expected_fault;
  bit expected_forwardable;
  logic [31:0] expected_forward_value;
  bit source_fault;
  int completion_waits = 0, completion_forwards = 0;
  int bypass_retirements = 0, bypass_backpressure = 0;
  initial begin
    flush                = 0;
    allocation_handshake = 0;
    recover              = 0;
    uop                  = '0;
    head_ready           = 0;
    recovery_tag         = 0;
    foreach (completion_array[p]) completion_array[p] = '0;
    repeat (3) @(negedge clk);
    rst = 1;
    void'($urandom(seed));
    for (int cycle = 0; cycle < 10000; cycle++) begin
      @(negedge clk);
      flush          = ($urandom_range(0, 99) == 0);
      recover        = queue.size() > 0 && !flush && ($urandom_range(0, 19) == 0);
      survivor_count = queue.size();
      if (recover) begin
        survivor_count = $urandom_range(1, queue.size());
        recovery_tag   = queue[survivor_count-1].tag;
        recoveries++;
      end
      head_ready = ($urandom_range(0, 3) != 0);
      completes  = 0;
      foreach (completion_array[p]) completion_array[p] = '0;
      // 随机完成未完成指令，允许一个周期多个 FU 返回；避免重复选择。
      for (int i = 0; i < queue.size(); i++) begin
        if (!queue[i].done && completes < BACKEND_PORTS && $urandom_range(0, 2) != 0) begin
          selected = (completes + cycle) % BACKEND_PORTS;
          completion_array[selected].valid = 1;
          completion_array[selected].tag = queue[i].tag;
          completion_array[selected].value = queue[i].pc ^ 32'h5a5a1234;
          completion_array[selected].next_pc = queue[i].pc + 4;
          completion_array[selected].exception_valid=(selected==0 || selected==3) &&
                                                  $urandom_range(0, 15) == 0;
          completes++;
        end
      end
      if (completes > 1) simultaneous++;
      expected_valid = 0;
      expected_value = 0;
      expected_fault = 0;
      if (queue.size() > 0) begin
        expected_valid = queue[0].done;
        expected_value = queue[0].value;
        expected_fault = queue[0].fault;
        // ALU/MUL 队首完成可退休；DIV/LSU 仍等待完成写入。
        for (int p = 0; p < 2; p++) begin
          if (completion_array[p].valid && completion_array[p].tag == queue[0].tag) begin
            expected_valid = 1;
            expected_value = completion_array[p].value;
            expected_fault = completion_array[p].exception_valid;
            if (head_ready) bypass_retirements++;
            else bypass_backpressure++;
          end
        end
      end
      retire_handshake     = expected_valid && head_ready;
      allocation_handshake = !flush && !recover && $urandom_range(0, 3) != 0;
      uop                  = '0;
      uop.pc               = 32'h80000000 + 32'(sequence_number * 4);
      uop.writes_rd        = 1;
      uop.rd               = arch_reg_idx_t'((sequence_number % 31) + 1);
      #1;
      assert (head_valid == expected_valid)
      else $fatal(1, "head validity cycle=%0d", cycle);
      assert (int'(count) == queue.size())
      else $fatal(1, "occupancy");
      assert (ready == (queue.size() < BACKEND_ENTRIES || retire_handshake))
      else $fatal(1, "full exchange");
      if (queue.size() > 0 && !queue[0].done) begin
        foreach (completion_array[p])
        if (p >= 2 && completion_array[p].valid && completion_array[p].tag == queue[0].tag)
          completion_waits++;
      end
      if (head_valid) begin
        assert(head.uop.pc==queue[0].pc && head.result==expected_value &&
               head.uop.exception_valid==expected_fault)
        else $fatal(1, "retirement result");
      end
      foreach (queue[i]) begin
        expected_forwardable = queue[i].done;
        expected_forward_value = queue[i].value;
        source_fault = queue[i].fault;
        foreach (completion_array[p]) begin
          if (completion_array[p].valid && completion_array[p].tag == queue[i].tag) begin
            expected_forwardable = 1;
            expected_forward_value = completion_array[p].value;
            source_fault = completion_array[p].exception_valid;
            completion_forwards++;
          end
        end
        expected_forwardable &= !source_fault;
        assert (producer_array[queue[i].tag].present &&
                producer_array[queue[i].tag].forwardable == expected_forwardable)
        else $fatal(1, "completion forwarding readiness");
        if (expected_forwardable)
          assert (producer_array[queue[i].tag].value == expected_forward_value)
          else $fatal(1, "completion forwarding value");
        assert (cancel_vector[queue[i].tag] == (recover && i >= survivor_count))
        else $fatal(1, "age_array cancel_vector");
        for (int p = 0; p < BACKEND_PORTS; p++) begin
          if (completion_array[p].valid && completion_array[p].tag == queue[i].tag) begin
            queue[i].done  = 1;
            queue[i].value = completion_array[p].value;
            queue[i].fault = completion_array[p].exception_valid;
          end
        end
      end
      input_accept = allocation_handshake && ready;
      if (queue.size() == BACKEND_ENTRIES && retire_handshake && input_accept) exchanges++;
      if (flush) queue.delete();
      else begin
        while (queue.size() > survivor_count) item = queue.pop_back();
        if (retire_handshake) begin
          item = queue.pop_front();
          popped++;
        end
        if (input_accept) begin
          item     = '0;
          item.tag = tail;
          item.pc  = uop.pc;
          queue.push_back(item);
          sequence_number++;
        end
      end
      @(posedge clk);
      #1;
    end
    assert (completion_waits > 10 && completion_forwards > 100);
    assert (bypass_retirements > 10 && bypass_backpressure > 10);
    assert (popped > 100 && recoveries > 10 && simultaneous > 10 && exchanges > 10);
    $display("PASS ROB entries=%0d retired=%0d multi_completion=%0d recovery=%0d full_exchange=%0d",
             BACKEND_ENTRIES, popped, simultaneous, recoveries, exchanges);
    $finish;
  end
endmodule
