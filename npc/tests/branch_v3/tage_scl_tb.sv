module tage_scl_tb #(
    parameter int BASE_ENTRIES = 32,
    TAGGED_ENTRIES = 16, TABLE_COUNT = 3, TAG_BITS = 8,
    HISTORY_BITS_0 = 3, HISTORY_BITS_1 = 7, HISTORY_BITS_2 = 16,
    parameter bit SC_ENABLE = 0,
    LOOP_ENABLE = 0
);
  logic clk = 0, rst_n = 0;
  logic [31:0] pc;
  logic train_valid, taken, invalidate, prediction;
  logic [191:0] query_context, train_context, saved[64];
  logic [8191:0] state_bits;
  riscv32_tage_scl #(
      .BASE_ENTRIES(BASE_ENTRIES),.TAGGED_ENTRIES(TAGGED_ENTRIES),.TABLE_COUNT(TABLE_COUNT),
      .TAG_BITS(TAG_BITS),.HISTORY_BITS_0(HISTORY_BITS_0),.HISTORY_BITS_1(HISTORY_BITS_1),.HISTORY_BITS_2(HISTORY_BITS_2),
      .SC_ENABLE  (SC_ENABLE),
      .LOOP_ENABLE(LOOP_ENABLE)
  ) dut (
      .lookup_handshake_i(1'b0),.lookup_conditional_i(1'b0),.lookup_taken_i(1'b0),.flush_i(1'b0),
      .clk_i(clk),
      .rst_ni(rst_n),
      .lookup_pc_i(pc),
      .taken_o(prediction),
      .context_o(query_context),
      .training_valid_i(train_valid),
      .training_taken_i(taken),
      .training_context_i(train_context),
      .invalidate_i(invalidate),
      .state_o(state_bits)
  );
  int input_fd, output_fd, rc, slot, train_slot, tv, tk, iv, count = 0;
  logic [191:0] next_context;
  logic prediction_before;
  string input_path, output_path;
  initial begin : check_counter_boundaries
    int lower_bounds[5] = '{0, -4, -8, -16, 1};
    int upper_bounds[5] = '{3, 3, 7, 15, 31};
    int expected;
    foreach (lower_bounds[kind]) begin
      for (int value = lower_bounds[kind]; value <= upper_bounds[kind]; value++) begin
        for (int up = 0; up <= 1; up++) begin
          expected = value + (up ? 1 : -1);
          if (expected < lower_bounds[kind]) expected = lower_bounds[kind];
          if (expected > upper_bounds[kind]) expected = upper_bounds[kind];
          assert (dut.saturating_step(value, 1'(up), lower_bounds[kind], upper_bounds[kind]) == expected)
            else $fatal(1, "Counter saturation mismatch kind=%0d value=%0d up=%0d", kind, value, up);
        end
      end
    end
  end
  initial begin
    if (!$value$plusargs("input=%s", input_path) || !$value$plusargs("output=%s", output_path))
      $fatal;
    input_fd = $fopen(input_path, "r");
    output_fd = $fopen(output_path, "w");
    pc = 0;
    train_valid = 0;
    taken = 0;
    invalidate = 0;
    train_context = 0;
    for (int i = 0; i < 64; i++) saved[i] = 0;
    #1;
    clk = 1;
    #1;
    clk   = 0;
    rst_n = 1;
    while (!$feof(
        input_fd
    )) begin
      rc = $fscanf(input_fd, "%h %d %d %d %d %d\n", pc, slot, train_slot, tv, tk, iv);
      if (rc != 6) $fatal(1, "bad vector");
      train_context = saved[train_slot];
      train_valid = 1'(tv);
      taken = 1'(tk);
      invalidate = 1'(iv);
      #1;
      next_context = query_context;
      prediction_before = prediction;
      clk = 1;
      #1;
      $fdisplay(output_fd, "%0d %h %h", prediction_before, next_context, state_bits);
      clk = 0;
      saved[slot] = next_context;
      count++;
    end
    $display("PASS ran %0d full-state steps SC=%0d loop=%0d", count, SC_ENABLE, LOOP_ENABLE);
    $finish;
  end
endmodule
