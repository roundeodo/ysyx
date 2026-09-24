// Independent delayed-training reference; no DUT helper or implementation index is reused.
module riscv32_direction_contract_tb;
  import riscv32_pkg::*;
  localparam int N = riscv_config_pkg::BRANCH_HISTORY_ENTRY_COUNT;
  localparam int POLICY = riscv_config_pkg::BRANCH_DIRECTION_POLICY;
  localparam int H = riscv_config_pkg::BRANCH_GLOBAL_HISTORY_BITS;
  logic clk = 0, rst_n = 0, train_valid = 0, train_taken = 0, invalidate = 0;
  always #5 clk = ~clk;
  program_counter_t lookup_pc, train_pc;
  direction_context_t context_out, train_context;
  logic [1:0] counter;
  riscv32_bht dut(.clk_i(clk), .rst_ni(rst_n), .lookup_pc_i(lookup_pc),
      .lookup_counter_o(counter), .lookup_context_o(context_out), .training_pc_i(train_pc),
      .training_valid_i(train_valid), .training_taken_i(train_taken),
      .training_context_i(train_context), .invalidate_i(invalidate));

  int flat[N], choice[N/2], taken_table[N/4], not_taken_table[N/4];
  int history = 0;
  typedef struct packed {program_counter_t pc; direction_context_t snapshot;} sample_t;
  sample_t pending[$], sample;
  int trained = 0, delayed = 0, banks[2], chooser_held = 0, invalidations = 0;
  int unsigned random_state = 32'hf07a391b;
  function automatic int unsigned random_value();
    random_state ^= random_state << 13;
    random_state ^= random_state >> 17;
    random_state ^= random_state << 5;
    return random_state;
  endfunction
  function automatic int updated(input int value, input bit outcome);
    if (outcome && value < 3) return value + 1;
    if (!outcome && value > 0) return value - 1;
    return value;
  endfunction
  task automatic initialize_model;
    history = 0;
    foreach (flat[i]) flat[i] = 1;
    foreach (choice[i]) choice[i] = 1;
    foreach (taken_table[i]) begin taken_table[i] = 2; not_taken_table[i] = 1; end
    pending.delete();
  endtask
  initial begin
    lookup_pc = 0; train_pc = 0; train_context = '0;
    initialize_model();
    repeat (2) @(negedge clk);
    rst_n = 1;
    for (int step = 0; step < 20000; step++) begin
      int index, selected, expected_counter;
      direction_context_t expected_context;
      @(negedge clk);
      invalidate = (step % 401 == 400);
      train_valid = pending.size() > 0 && (random_value() % 4 != 0);
      if (train_valid) begin
        sample = pending.pop_front(); train_pc = sample.pc; train_context = sample.snapshot;
        train_taken = (random_value() % 8) < (2 + ((train_pc >> 3) % 5));
      end
      lookup_pc = 32'h80000000 + 4 * (random_value() % 256);
      #1;
      expected_context = '0;
      if (POLICY == 0) begin
        index = (lookup_pc / 4) % N;
        expected_counter = flat[index];
      end else if (POLICY == 1) begin
        index = ((lookup_pc / 4) % N) ^ (history * (N / (2 ** H)));
        expected_counter = flat[index]; expected_context.history = H'(history);
      end else begin
        index = ((lookup_pc / 4) % (N/4)) ^ history;
        selected = choice[(lookup_pc / 4) % (N/2)] >= 2;
        expected_counter = selected ? taken_table[index] : not_taken_table[index];
        expected_context.history = H'(history);
        expected_context.choice = 1'(selected); expected_context.taken = expected_counter >= 2;
      end
      if (counter != expected_counter || context_out != expected_context)
        $fatal(1,"query mismatch step=%0d policy=%0d pc=%h counter=%0d/%0d context=%h/%h",step,POLICY,lookup_pc,counter,expected_counter,context_out,expected_context);
      // Model accepted queries and squashed young transactions separately from table state.
      if (step % 173 == 172 || invalidate) pending.delete();
      else if (pending.size() < 32 && random_value() % 5 != 0) begin
        sample.pc = lookup_pc; sample.snapshot = expected_context; pending.push_back(sample);
      end
      @(posedge clk);
      if (invalidate) begin history = 0; invalidations++; end
      else if (train_valid) begin
        trained++;
        if (train_context.history != H'(history)) delayed++;
        if (POLICY == 0) flat[(train_pc/4)%N] = updated(flat[(train_pc/4)%N],train_taken);
        else if (POLICY == 1) begin
          index = ((train_pc/4)%N) ^ (int'(train_context.history) * (N/(2**H)));
          flat[index] = updated(flat[index],train_taken);
        end else begin
          index = ((train_pc/4)%(N/4)) ^ int'(train_context.history);
          selected = int'(train_context.choice); banks[selected]++;
          if (selected) taken_table[index] = updated(taken_table[index],train_taken);
          else not_taken_table[index] = updated(not_taken_table[index],train_taken);
          if (train_context.taken != train_taken || train_context.choice == train_taken)
            choice[(train_pc/4)%(N/2)] = updated(choice[(train_pc/4)%(N/2)],train_taken);
          else chooser_held++;
        end
        if (POLICY != 0) history = ((history * 2) + int'(train_taken)) % (2 ** H);
      end
    end
    if (trained < 5000 || invalidations < 40) $fatal(1,"insufficient event coverage");
    if (POLICY != 0 && delayed < 1000) $fatal(1,"delayed metadata not covered");
    if (POLICY == 2 && (banks[0] < 100 || banks[1] < 100 || chooser_held < 100))
      $fatal(1,"bi-mode choice coverage incomplete");
    $display("PASS direction policy=%0d entries=%0d history=%0d trained=%0d delayed=%0d banks=%0d/%0d held=%0d",POLICY,N,H,trained,delayed,banks[0],banks[1],chooser_held);
    $finish;
  end
endmodule
