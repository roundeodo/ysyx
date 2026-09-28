// Read latency starts at accepted AR; B latency starts at accepted last W.
// One shared read burst, independent write burst, stable stalled responses.
// physical: beat availability follows cumulative nanosecond deadlines from AR.
// cycle: legacy service interval restarts after each accepted beat (rounded up).
module exploration_axi_memory
  import riscv32_axi4_pkg::*;
(
    input logic clk_i, rst_ni,
    input axi4_manager_to_target_t request_i,
    output axi4_target_to_manager_t response_o,
    output logic result_valid_o,
    output logic [31:0] result_o
);
  logic [31:0] words[32768];
  axi4_read_address_t read_address_q;
  axi4_write_address_t write_address_q;
  logic read_present_q = 0, write_present_q = 0, write_complete_q = 0;
  int read_beat_q = 0, write_beat_q = 0, read_wait_q = 0, write_wait_q = 0;
  int cpu_mhz = 580, latency_ns = 100, beat_ns = 10, random_stalls = 0;
  int first_cycles, beat_cycles, cycle = 0, accept_after = 0;
  logic [31:0] random_q = 1;
  longint read_due_scaled_q = 0;
  logic read_stalled_q = 0;
  logic [31:0] read_stalled_data_q;
  string image, memory_mode = "cycle";
  function automatic logic [31:0] read_word(input logic [31:0] address);
    if (address >= 32'h80000000 && address < 32'h80020000)
      return words[(address - 32'h80000000) >> 2];
    return 0;
  endfunction
  initial begin
    foreach (words[i]) words[i] = 0;
    if ($value$plusargs("image=%s", image)) $readmemh(image, words);
    void'($value$plusargs("cpu_mhz=%d", cpu_mhz));
    void'($value$plusargs("latency_ns=%d", latency_ns));
    void'($value$plusargs("beat_ns=%d", beat_ns));
    void'($value$plusargs("random_stalls=%d", random_stalls));
    void'($value$plusargs("seed=%d", random_q));
    void'($value$plusargs("accept_after=%d", accept_after));
    void'($value$plusargs("memory_mode=%s", memory_mode));
    if (memory_mode != "cycle" && memory_mode != "physical")
      $fatal(1, "unknown reference memory mode");
    first_cycles = (latency_ns * cpu_mhz + 999) / 1000;
    beat_cycles = (beat_ns * cpu_mhz + 999) / 1000;
    if (first_cycles < 1 || beat_cycles < 1) $fatal(1, "positive service time required");
  end
  always_comb begin
    response_o = '0;
    response_o.ar_ready = !read_present_q && cycle >= accept_after &&
        (!random_stalls || random_q[0]);
    response_o.r_valid = read_present_q && ((memory_mode == "physical") ?
        (longint'(cycle) * 1000 >= read_due_scaled_q) : (read_wait_q == 0));
    response_o.r.id = read_address_q.id;
    response_o.r.data = read_stalled_q ? read_stalled_data_q :
        read_word(read_address_q.addr + (32'(read_beat_q) << read_address_q.size));
    response_o.r.last = read_beat_q == int'(read_address_q.len);
    response_o.r.resp = AXI4_RESP_OKAY;
    response_o.aw_ready = !write_present_q && (!random_stalls || random_q[1]);
    response_o.w_ready = write_present_q && !write_complete_q && (!random_stalls || random_q[2]);
    response_o.b_valid = write_present_q && write_complete_q && write_wait_q == 0;
    response_o.b.id = write_address_q.id;
    response_o.b.resp = AXI4_RESP_OKAY;
    result_valid_o = request_i.w_valid && response_o.w_ready && write_address_q.addr == 32'h10002000;
    result_o = request_i.w.data;
  end
  always @(posedge clk_i) if (rst_ni) begin
    cycle <= cycle + 1;
    random_q <= {random_q[30:0], random_q[31]^random_q[21]^random_q[1]^random_q[0]};
    if (request_i.ar_valid && response_o.ar_ready) begin
      read_address_q <= request_i.ar;
      read_present_q <= 1;
      read_beat_q <= 0;
      read_wait_q <= first_cycles - 1;
      read_due_scaled_q <= longint'(cycle) * 1000 + longint'(latency_ns) * cpu_mhz;
    end else if (read_wait_q > 0) read_wait_q <= read_wait_q - 1;
    // A concurrent write may change memory while R is stalled. Preserve the
    // already presented payload without adding a response pipeline stage.
    if (response_o.r_valid && !request_i.r_ready) begin
      read_stalled_q <= 1;
      read_stalled_data_q <= response_o.r.data;
    end
    if (response_o.r_valid && request_i.r_ready) begin
      read_stalled_q <= 0;
      if (response_o.r.last) read_present_q <= 0;
      else begin
        read_beat_q <= read_beat_q + 1;
        read_wait_q <= beat_cycles - 1;
        read_due_scaled_q <= read_due_scaled_q + longint'(beat_ns) * cpu_mhz;
      end
    end
    if (request_i.aw_valid && response_o.aw_ready) begin
      write_address_q <= request_i.aw;
      write_present_q <= 1;
      write_complete_q <= 0;
      write_beat_q <= 0;
    end
    if (request_i.w_valid && response_o.w_ready) begin
      if (write_address_q.addr >= 32'h80000000 && write_address_q.addr < 32'h80020000)
        for (int byte_index = 0; byte_index < 4; byte_index++)
          if (request_i.w.strb[byte_index])
            words[((write_address_q.addr-32'h80000000) >> 2)+write_beat_q][byte_index*8+:8]
                <= request_i.w.data[byte_index*8+:8];
      write_beat_q <= write_beat_q + 1;
      if (request_i.w.last) begin
        write_complete_q <= 1;
        write_wait_q <= first_cycles - 1;
      end
    end else if (write_wait_q > 0) write_wait_q <= write_wait_q - 1;
    if (response_o.b_valid && request_i.b_ready) write_present_q <= 0;
  end
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    response_o.r_valid && !request_i.r_ready |=> response_o.r_valid && $stable(response_o.r));
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    response_o.b_valid && !request_i.b_ready |=> response_o.b_valid && $stable(response_o.b));
endmodule
