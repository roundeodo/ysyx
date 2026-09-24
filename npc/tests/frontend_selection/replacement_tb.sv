// Compare every physical victim against the separately implemented C++ model.
module selection_replacement_tb;
  import riscv32_pkg::*;
  import riscv32_addr_map_pkg::*;
  logic clk = 0;
  always #5 clk = !clk;
  logic reset_n = 0, invalidate = 0, read_enable = 0, hit = 0, allocate = 0;
  icache_set_index_t read_set;
  icache_way_index_t read_victim, allocate_way;
  logic [ICACHE_WAY_COUNT-1:0] hit_vector;
  logic victim_present;
  phys_addr_t address;
  riscv32_icache_replacement dut (
      .clk_i(clk), .rst_ni(reset_n), .invalidate_i(invalidate),
      .read_enable_i(read_enable), .read_set_i(read_set), .read_victim_o(read_victim),
      .hit_i(hit), .hit_way_vector_i(hit_vector), .allocate_i(allocate),
      .allocate_way_i(allocate_way), .victim_present_i(victim_present), .access_addr_i(address)
  );
  logic present [ICACHE_SET_COUNT][ICACHE_WAY_COUNT];
  phys_addr_t tags [ICACHE_SET_COUNT][ICACHE_WAY_COUNT];
  phys_addr_t addresses [65536];
  int misses [65536], ways [65536];
  int count = 0, fd, status, set_index, actual_way;
  logic actual_miss;
  string path;
  icache_way_index_t held_victim;

  function automatic icache_set_index_t set_of(input phys_addr_t addr);
    return ICACHE_SET_COUNT == 1 ? '0 : icache_set_index_t'(addr >> ICACHE_LINE_OFFSET_W);
  endfunction

  initial begin
    if (!$value$plusargs("events=%s", path)) $fatal(1, "events required");
    fd = $fopen(path, "r");
    if (!fd) $fatal(1, "cannot open events");
    while (!$feof(fd)) begin
      status = $fscanf(fd, "%h %d %d\n", addresses[count], misses[count], ways[count]);
      if (status == 3) count++;
      if (count >= 65535) $fatal(1, "too many events");
    end
    $fclose(fd);
    if (count == 0) $fatal(1, "empty events");
    hit_vector = '0;
    victim_present = 0;
    allocate_way = '0;
    address = '0;
    repeat (2) @(negedge clk);
    reset_n = 1;
    // Repeating after invalidate must reproduce all decisions, including history.
    for (int pass = 0; pass < 2; pass++) begin
      invalidate = 1;
      hit = 0;
      allocate = 0;
      read_enable = 0;
      for (int s = 0; s < ICACHE_SET_COUNT; s++)
        for (int w = 0; w < ICACHE_WAY_COUNT; w++) present[s][w] = 0;
      @(negedge clk);
      invalidate = 0;
      read_enable = 1;
      read_set = set_of(addresses[0]);
      @(negedge clk);
      for (int index = 0; index < count; index++) begin
        address = addresses[index];
        set_index = int'(set_of(address));
        actual_way = -1;
        for (int w = 0; w < ICACHE_WAY_COUNT; w++)
          if (present[set_index][w] && tags[set_index][w] == address) actual_way = w;
        actual_miss = actual_way < 0;
        if (actual_miss) begin
          actual_way = int'(read_victim);
          for (int w = ICACHE_WAY_COUNT-1; w >= 0; w--)
            if (!present[set_index][w]) actual_way = w;
        end
        if (actual_miss != misses[index] || actual_way != ways[index])
          $fatal(1, "decision %0d pass %0d addr %h: miss/way %0d/%0d expected %0d/%0d",
                 index, pass, address, actual_miss, actual_way, misses[index], ways[index]);
        // Insert deterministic irregular backpressure; the victim snapshot holds.
        if ((index % 29) == 7) begin
          held_victim = read_victim;
          hit = 0;
          allocate = 0;
          read_enable = 0;
          read_set = icache_set_index_t'(index);
          repeat (index % 3 + 1) begin
            @(negedge clk);
            if (read_victim != held_victim) $fatal(1, "snapshot changed under backpressure");
          end
        end
        hit = !actual_miss;
        hit_vector = ICACHE_WAY_COUNT'(1) << actual_way;
        allocate = actual_miss;
        allocate_way = icache_way_index_t'(actual_way);
        victim_present = present[set_index][actual_way];
        present[set_index][actual_way] = 1;
        tags[set_index][actual_way] = address;
        // Next request read shares the edge with this hit/allocation update.
        read_enable = (index + 1 < count) &&
                      !(riscv_config_pkg::ICACHE_REPLACEMENT_POLICY >= 13 && actual_miss);
        read_set = set_of(addresses[index + 1]);
        @(negedge clk);
        if (riscv_config_pkg::ICACHE_REPLACEMENT_POLICY >= 13 && actual_miss && index + 1 < count) begin
          allocate = 0;
          hit = 0;
          read_enable = 1;
          @(negedge clk);
        end
      end
    end
    $display("PASS replacement: %0d decisions, invalidate, forwarding, snapshot hold", count * 2);
    $finish;
  end
endmodule
