module riscv32_compact_btb_tb;
  import riscv32_pkg::*;
  localparam int ENTRIES = BRANCH_TARGET_ENTRY_COUNT;
  localparam int WAYS = BRANCH_TARGET_WAY_COUNT;
  localparam int SETS = ENTRIES / WAYS;
  localparam logic [31:0] WIDTHS = riscv_config_pkg::BRANCH_TARGET_WAY_BITS;
  localparam int POLICY = riscv_config_pkg::BRANCH_TARGET_POLICY;
  logic clk = 0, rst_n = 0, training_valid = 0, training_taken = 0, invalidate = 0;
  always #5 clk = ~clk;
  program_counter_t lookup_pc = 0, training_pc = 0, training_target = 0, predicted_target;
  branch_target_kind_e training_kind = TARGET_KIND_CONDITIONAL_BRANCH, predicted_kind;
  logic predicted_present;
  riscv32_btb dut (
      .clk_i(clk),
      .rst_ni(rst_n),
      .lookup_pc_i(lookup_pc),
      .lookup_target_present_o(predicted_present),
      .lookup_target_pc_o(predicted_target),
      .lookup_target_kind_o(predicted_kind),
      .training_pc_i(training_pc),
      .training_target_pc_i(training_target),
      .training_kind_i(training_kind),
      .training_valid_i(training_valid),
      .training_taken_i(training_taken),
      .invalidate_i(invalidate)
  );

  // Independent reference stores full PCs/targets, never compressed payloads.
  typedef struct packed {
    bit present;
    logic [31:0] pc, target;
    branch_target_kind_e kind;
  } entry_t;
  entry_t entries[SETS][WAYS];
  int next_victim[SETS];
  int checked = 0, migrations = 0, rejected = 0, invalidations = 0;
  logic [31:0] random_state = 32'h67230923;

  function automatic logic [31:0] random_word();
    random_state = random_state * 32'd1664525 + 32'd1013904223;
    return random_state;
  endfunction

  function automatic bit fits(int way);
    int width;
    width = WIDTHS == 0 ? 32 : int'(WIDTHS[way*8+:8]);
    return width == 32 || (training_pc >> width) == (training_target >> width);
  endfunction

  task automatic clear_model();
    foreach (entries[set_index, way]) entries[set_index][way] = '0;
    foreach (next_victim[set_index]) next_victim[set_index] = 0;
  endtask

  task automatic check_lookup();
    int set_index, match_count;
    entry_t expected;
    set_index = int'((lookup_pc >> 2) & (SETS - 1));
    expected = '0;
    match_count = 0;
    for (int way = 0; way < WAYS; way++) begin
      if (entries[set_index][way].present && entries[set_index][way].pc == lookup_pc) begin
        match_count++;
        expected = entries[set_index][way];
      end
    end
    if (match_count > 1 || predicted_present != expected.present ||
        (expected.present && (predicted_target != expected.target || predicted_kind != expected.kind)))
      $fatal(
          1,
          "lookup mismatch cycle=%0d pc=%h present=%b/%b target=%h/%h kind=%0d/%0d",
          checked,
          lookup_pc,
          predicted_present,
          expected.present,
          predicted_target,
          expected.target,
          predicted_kind,
          expected.kind
      );
  endtask

  task automatic train_model();
    int set_index, hit, chosen;
    bit replacing;
    if (!rst_n || invalidate) begin
      clear_model();
      invalidations++;
    end else if (training_valid) begin
      set_index = int'((training_pc >> 2) & (SETS - 1));
      hit = -1;
      for (int way = 0; way < WAYS; way++)
      if (entries[set_index][way].present && entries[set_index][way].pc == training_pc) hit = way;
      if (POLICY == 0 || hit >= 0 || training_taken || training_kind != TARGET_KIND_CONDITIONAL_BRANCH) begin
        if (hit >= 0 && !fits(hit)) begin
          entries[set_index][hit].present = 0;
          hit = -1;
          migrations++;
        end
        chosen = hit;
        replacing = 0;
        for (int way = WAYS - 1; way >= 0; way--)
        if (hit < 0 && fits(way) && !entries[set_index][way].present) chosen = way;
        if (chosen < 0) begin
          for (int distance = WAYS - 1; distance >= 0; distance--)
          if (fits((next_victim[set_index] + distance) % WAYS))
            chosen = (next_victim[set_index] + distance) % WAYS;
          replacing = chosen >= 0;
        end
        if (chosen >= 0) begin
          entries[set_index][chosen] = '{1'b1, training_pc, training_target, training_kind};
          if (replacing) next_victim[set_index] = (chosen + 1) % WAYS;
        end else rejected++;
      end
    end
  endtask

  task automatic step(logic [31:0] pc, logic [31:0] target, int kind, bit update, bit taken, bit clear,
                      bit reset, logic [31:0] query);
    @(negedge clk);
    rst_n = !reset;
    training_pc = pc;
    training_target = target;
    training_kind = branch_target_kind_e'(kind);
    training_valid = update;
    training_taken = taken;
    invalidate = clear;
    lookup_pc = query;
    if (reset) clear_model();
    #1;
    check_lookup();
    @(posedge clk);
    #1;
    train_model();
    check_lookup();
    checked++;
  endtask

  initial begin
    logic [31:0] pc, target, query, choice;
    clear_model();
    step(0, 0, 0, 0, 0, 0, 1, 0);
    // Same PC moves across every width boundary, including unaligned targets.
    for (int bit_index = 0; bit_index < 32; bit_index++) begin
      step(32'h80001000, 32'h80001000 ^ (32'b1 << bit_index), bit_index % 4, 1, 1, 0, 0, 32'h80001000);
      step(32'h80001000, 32'h80001004, 0, 1, 0, 0, 0, 32'h80001000);
    end
    for (int cycle = 0; cycle < 20000; cycle++) begin
      choice = random_word();
      pc = 32'h80000000 | ((random_word() >> 8) & 32'h000001fc);
      target = pc ^ (32'b1 << (choice % 32));
      if (choice[3:0] < 5) target = pc + ((random_word() >> 16) & 255);
      query = choice[4] ? pc : 32'h80000000 | ((random_word() >> 8) & 32'h000001fc);
      step(pc, target, int'(choice[6:5]), choice[7:6] != 0, choice[8], cycle % 701 == 0,
           cycle % 4093 == 0, query);
    end
    $display("PASS compact BTB checks=%0d migrations=%0d rejected=%0d invalidations=%0d", checked,
             migrations, rejected, invalidations);
    $finish;
  end
endmodule
