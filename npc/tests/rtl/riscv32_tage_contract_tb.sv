module riscv32_tage_contract_tb;
  import riscv32_pkg::*;
  logic clk = 0;
  logic rst_n = 0;
  program_counter_t lookup_pc, training_pc;
  logic [1:0] counter;
  direction_context_t context_out, training_context;
  logic training_valid, training_taken, invalidate;
  riscv32_bht dut (
      .clk_i(clk), .rst_ni(rst_n), .lookup_pc_i(lookup_pc),
      .lookup_counter_o(counter), .lookup_context_o(context_out),
      .training_pc_i(training_pc), .training_valid_i(training_valid),
      .training_taken_i(training_taken), .training_context_i(training_context),
      .invalidate_i(invalidate)
  );
  initial begin
    string path;
    integer fd, count, fields;
    int reset_value, invalidate_value, expected_history, expected_taken;
    int expected_provider, expected_alternate_provider, expected_alternate;
    int valid_value, train_history, train_provider, train_alt_provider;
    int train_prediction, train_alternate, train_actual;
    training_valid = 0;
    training_context = '0;
    training_taken = 0;
    training_pc = 0;
    lookup_pc = 0;
    invalidate = 0;
    #1; clk = 1; #1; clk = 0; rst_n = 1;
    if (!$value$plusargs("vectors=%s", path)) $fatal(1, "missing vectors");
    fd = $fopen(path, "r");
    if (!fd) $fatal(1, "cannot open vectors");
    count = 0;
    while (!$feof(fd)) begin
      fields = $fscanf(fd, "%d %d %h %h %d %d %d %d %d %h %h %d %d %d %d %d\n",
                       reset_value, invalidate_value, lookup_pc,
                       expected_history, expected_taken, expected_provider,
                       expected_alternate_provider, expected_alternate, valid_value,
                       training_pc, train_history, train_provider, train_alt_provider,
                       train_prediction, train_alternate, train_actual);
      if (fields != 16) $fatal(1, "malformed vector at %0d", count);
      rst_n = !reset_value;
      invalidate = 1'(invalidate_value);
      training_valid = 1'(valid_value);
      training_taken = 1'(train_actual);
      training_context = '0;
      training_context.history = 16'(train_history);
      training_context.provider = 2'(train_provider);
      training_context.alternate_provider = 2'(train_alt_provider);
      training_context.taken = 1'(train_prediction);
      training_context.alternate_taken = 1'(train_alternate);
      #1;
      if (context_out.history !== 16'(expected_history) ||
          counter[1] !== 1'(expected_taken) || context_out.taken !== counter[1] ||
          context_out.provider !== 2'(expected_provider) ||
          context_out.alternate_provider !== 2'(expected_alternate_provider) ||
          context_out.alternate_taken !== 1'(expected_alternate))
        $fatal(1, "TAGE query mismatch cycle=%0d pc=%h got=%h expected h=%h p=%d provider=%d altprovider=%d alt=%d",
               count, lookup_pc, context_out, expected_history, expected_taken,
               expected_provider, expected_alternate_provider, expected_alternate);
      clk = 1; #1; clk = 0; #1;
      count++;
    end
    if (count < 20000) $fatal(1, "truncated test");
    $display("PASS TAGE snapshots, delayed replacement, invalidate priority: %0d cycles", count);
    $finish;
  end
endmodule
