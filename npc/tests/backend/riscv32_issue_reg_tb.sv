module riscv32_issue_reg_tb;
  import riscv32_pkg::*;
  logic clk = 0, rst_ni = 0, flush = 0;
  decoded_uop_t input_uop, output_uop;
  logic input_valid = 0, input_ready, output_valid, output_ready = 0;
  decoded_uop_t reference_queue[$];
  int accepted = 0, delivered = 0, simultaneous = 0, blocked_flush = 0;
  riscv32_issue_reg dut (
      .clk_i(clk),
      .rst_ni(rst_ni),
      .decoded_uop_i(input_uop),
      .decoded_uop_valid_i(input_valid),
      .decoded_uop_ready_o(input_ready),
      .issue_uop_o(output_uop),
      .issue_uop_valid_o(output_valid),
      .issue_uop_ready_i(output_ready),
      .flush_i(flush)
  );
  initial begin
    input_uop = '0;
    #1;
    clk = 1;
    #1;
    clk = 0;
    rst_ni = 1;
    for (int cycle = 0; cycle < 10000; cycle++) begin
      logic push, pop;
      decoded_uop_t expected;
      flush = cycle == 105 || (cycle > 110 && $urandom_range(0, 49) == 0);
      output_ready = cycle < 100 || (cycle > 106 && $urandom_range(0, 3) != 0);
      if (!input_valid && (cycle < 110 || $urandom_range(0, 4) != 0)) begin
        input_valid = 1;
        for (int bit_index = 0; bit_index < $bits(decoded_uop_t); bit_index++)
        input_uop[bit_index] = 1'($urandom);
      end
      #1;
      assert (input_ready == (!flush && (reference_queue.size() == 0 || output_ready)))
      else $fatal(1, "Issue input readiness cycle=%0d", cycle);
      assert (output_valid == (!flush && reference_queue.size() == 1))
      else $fatal(1, "Issue must have one register boundary cycle=%0d", cycle);
      if (output_valid)
        assert (output_uop == reference_queue[0])
        else $fatal(1, "Issue payload/order cycle=%0d", cycle);
      if (cycle > 0 && cycle < 100)
        assert (output_valid)
        else $fatal(1, "Issue inserted a steady-state bubble cycle=%0d", cycle);
      push = input_valid && input_ready;
      pop  = output_valid && output_ready;
      if (push && pop) simultaneous++;
      if (flush && input_valid && reference_queue.size() != 0) blocked_flush++;
      clk = 1;
      if (flush) reference_queue.delete();
      else begin
        if (pop) expected = reference_queue.pop_front();
        if (push) reference_queue.push_back(input_uop);
      end
      accepted += int'(push);
      delivered += int'(pop);
      #1;
      clk = 0;
      if (push || flush) input_valid = 0;
    end
    assert (simultaneous > 0 && blocked_flush > 0);
    $display(
        "PASS Issue cycles=10000 accepted=%0d delivered=%0d simultaneous=%0d blocked_flush=%0d",
        accepted, delivered, simultaneous, blocked_flush);
    $finish;
  end
endmodule
