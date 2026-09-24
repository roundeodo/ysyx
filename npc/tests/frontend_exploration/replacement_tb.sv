// Check hint identity and priority through the public array interface, including
// a held read snapshot while the independent retirement feedback changes state.
module exploration_replacement_tb;
  import riscv32_pkg::*;
  localparam int POLICY = riscv_config_pkg::ICACHE_REPLACEMENT_POLICY;
  logic clk = 0, rst_n = 0, invalidate = 0, read_enable = 0;
  always #5 clk = ~clk;
  icache_set_index_t read_set = 0, write_set = 0, age_set = 0, hit_set = 0;
  icache_way_index_t write_way = 0;
  icache_tag_t write_tag = 0, tags[ICACHE_WAY_COUNT];
  logic [ICACHE_WAY_COUNT-1:0] present, hits = 0;
  logic [1:0] rrpv[ICACHE_WAY_COUNT], age_amount = 0;
  logic write_valid = 0, write_present = 0, age_valid = 0, hit_valid = 0, retired_valid = 0;
  program_counter_t retired_pc = 0;
  riscv32_icache_tag_array dut (
      .clk_i(clk), .rst_ni(rst_n), .invalidate_all_i(invalidate),
      .read_enable_i(read_enable), .read_set_index_i(read_set),
      .read_tag_array_o(tags), .read_line_present_vector_o(present), .read_rrpv_array_o(rrpv),
      .age_valid_i(age_valid), .age_set_index_i(age_set), .age_amount_i(age_amount),
      .hit_valid_i(hit_valid), .hit_set_index_i(hit_set), .hit_way_vector_i(hits),
      .retired_valid_i(retired_valid), .retired_pc_i(retired_pc),
      .metadata_write_valid_i(write_valid), .metadata_write_set_index_i(write_set),
      .metadata_write_way_index_i(write_way), .metadata_write_tag_i(write_tag),
      .metadata_write_line_present_i(write_present));
  function automatic program_counter_t address(input int tag_value, input int set_value);
    return program_counter_t'((tag_value << (ICACHE_LINE_OFFSET_W + ICACHE_SET_INDEX_BITS)) |
                             (set_value << ICACHE_LINE_OFFSET_W));
  endfunction
  task automatic tick;
    @(posedge clk); #1; @(negedge clk);
  endtask
  task automatic query(input int set_value);
    read_set = icache_set_index_t'(set_value); read_enable = 1;
    tick(); read_enable = 0;
  endtask
  task automatic install(input int tag_value);
    write_valid = 1; write_present = 1; write_tag = icache_tag_t'(tag_value);
    tick(); write_valid = 0;
  endtask
  task automatic expect_priority(input int expected, input string label);
    query(0);
    if (rrpv[0] != 2'(expected)) $fatal(1, "%s expected %0d got %0d",label,expected,rrpv[0]);
  endtask
  initial begin
    repeat (3) tick(); rst_n = 1;
    install(1);
    expect_priority(POLICY == 1 ? 2 : 3, "insertion");
    retired_pc = address(2,0); retired_valid = 1; tick(); retired_valid = 0;
    expect_priority(POLICY == 1 ? 2 : 3, "wrong tag must not promote");
    retired_pc = address(1,0); retired_valid = 1; tick(); retired_valid = 0;
    // Old synchronous snapshot must remain held until another explicit read.
    if (rrpv[0] != (POLICY == 1 ? 2 : 3)) $fatal(1, "feedback changed held snapshot");
    expect_priority(POLICY == 3 ? 0 : (POLICY == 1 ? 2 : 3), "retirement policy");
    install(2);
    hit_valid = 1; hits = 1; tick(); hit_valid = 0;
    expect_priority(POLICY == 3 ? 3 : 0, "hit promotion condition");
    // An old-line commit and a different new-line install share the clock edge.
    retired_pc = address(2,0); retired_valid = 1; install(3); retired_valid = 0;
    expect_priority(POLICY == 1 ? 2 : 3, "old identity at install");
    retired_pc = address(4,0); retired_valid = 1; install(4); retired_valid = 0;
    expect_priority(POLICY == 3 ? 0 : (POLICY == 1 ? 2 : 3), "install matching retirement bypass");
    write_valid = 1; write_present = 0; tick(); write_valid = 0;
    retired_valid = 1; tick(); retired_valid = 0;
    expect_priority(POLICY == 1 ? 2 : 3, "early or invalid hint ignored");
    install(4);
    age_valid = 1; age_amount = 3; retired_valid = 1; tick(); age_valid = 0; retired_valid = 0;
    expect_priority(POLICY == 3 ? 0 : 3, "retirement over aging");
    invalidate = 1; retired_valid = 1; tick(); invalidate = 0; retired_valid = 0;
    expect_priority(3, "invalidate over retirement");
    if (present != 0) $fatal(1, "invalidate retained presence");
    $display("PASS replacement identity and priority policy=%0d sets=%0d", POLICY, ICACHE_SET_COUNT);
    $finish;
  end
endmodule
