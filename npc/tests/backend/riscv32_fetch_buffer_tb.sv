module riscv32_fetch_buffer_tb;
  import riscv32_pkg::*;
  logic clk = 0, rst_ni = 0, flush = 0;
  fetch_entry_t input_entry, output_entry;
  logic input_valid = 0, input_ready, output_valid, output_ready = 0;
  fetch_entry_t reference_queue[$];
  int received = 0, delivered = 0, full_exchange = 0, blocked_flush = 0;
  riscv32_fetch_buffer dut (
      .clk_i(clk),
      .rst_ni(rst_ni),
      .ifu_fetch_entry_i(input_entry),
      .ifu_fetch_entry_valid_i(input_valid),
      .ifu_fetch_entry_ready_o(input_ready),
      .idu_fetch_entry_o(output_entry),
      .idu_fetch_entry_valid_o(output_valid),
      .idu_fetch_entry_ready_i(output_ready),
      .flush_i(flush)
  );
  initial begin
    input_entry = '0;
    #1;
    clk = 1;
    #1;
    clk = 0;
    rst_ni = 1;
    for (int cycle = 0; cycle < 10000; cycle++) begin
      logic push, pop, direct;
      fetch_entry_t expected;
      flush = cycle == 105 || (cycle > 110 && $urandom_range(0, 49) == 0);
      output_ready = !flush && (cycle < 100 || (cycle > 104 && $urandom_range(0, 3) != 0));
      if (!input_valid && (cycle < 110 || $urandom_range(0, 4) != 0)) begin
        input_valid = 1;
        input_entry = '0;
        input_entry.pc = program_counter_t'(received * 4);
        input_entry.instruction = 32'(received) ^ 32'h12345678;
      end
      #1;
      assert (input_ready == (!flush && (reference_queue.size() < 2 || output_ready)))
      else $fatal(1, "input readiness cycle=%0d", cycle);
      assert (output_valid == (reference_queue.size() != 0 || (input_valid && !flush)))
      else $fatal(1, "output validity cycle=%0d", cycle);
      expected = reference_queue.size() != 0 ? reference_queue[0] : input_entry;
      if (output_valid)
        assert (output_entry == expected)
        else $fatal(1, "payload/order cycle=%0d", cycle);
      if (cycle > 0 && cycle < 100)
        assert (output_valid)
        else $fatal(1, "unnecessary steady-state bubble cycle=%0d", cycle);
      push = input_valid && input_ready;
      pop = output_valid && output_ready;
      direct = reference_queue.size() == 0 && push && pop;
      if (reference_queue.size() == 2 && push && pop) full_exchange++;
      if (flush && input_valid && reference_queue.size() == 2) blocked_flush++;
      clk = 1;
      if (flush) reference_queue.delete();
      else begin
        if (pop && !direct) expected = reference_queue.pop_front();
        if (push && !direct) reference_queue.push_back(input_entry);
      end
      if (push) received++;
      if (pop) delivered++;
      #1;
      clk = 0;
      if (push || flush) input_valid = 0;
    end
    assert (full_exchange > 0 && blocked_flush > 0);
    $display(
        "PASS fetch flow-through cycles=10000 received=%0d delivered=%0d full_exchange=%0d blocked_flush=%0d",
        received, delivered, full_exchange, blocked_flush);
    $finish;
  end
endmodule
