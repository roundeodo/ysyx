// Independent closed-form timing oracle. This is a testbench, not DUT logic.
module exploration_memory_timing_tb;
  import riscv32_axi4_pkg::*;
  logic clk = 0, rst_n = 0, result_valid;
  logic [31:0] result;
  always #5 clk = ~clk;
  axi4_manager_to_target_t request;
  axi4_target_to_manager_t response;
  int cycle = 0, accepted = -1, previous = -1, beats = 0;
  int mhz = 580, latency_ns = 100, beat_ns = 10, burst_beats = 4;
  int present_at = 1, accept_after = 10, stalls = 0;
  bit aw_sent = 0, w_sent = 0;
  longint due_cycle;
  string mode = "physical";
  exploration_axi_memory u_memory (
      .clk_i(clk), .rst_ni(rst_n), .request_i(request), .response_o(response),
      .result_valid_o(result_valid), .result_o(result));
  always_comb begin
    if (mode == "physical")
      due_cycle = accepted + ((longint'(latency_ns) + longint'(beats) * beat_ns) * mhz + 999) / 1000;
    else if (beats == 0)
      due_cycle = accepted + (longint'(latency_ns) * mhz + 999) / 1000;
    else due_cycle = previous + (longint'(beat_ns) * mhz + 999) / 1000;
    request = '0;
    request.ar_valid = cycle >= present_at && accepted < 0;
    request.ar.addr = 32'h80000000;
    request.ar.id = 4'hb;
    request.ar.len = 8'(burst_beats - 1);
    request.ar.size = 2;
    request.ar.burst = AXI4_BURST_INCR;
    request.r_ready = 1;
    if (stalls == 1) request.r_ready = ((cycle * 13 + 7) % 19) < 6;
    if (stalls >= 2 && beats == 0) request.r_ready = cycle >= due_cycle + 30;
    if (stalls == 3) begin
      request.aw_valid = !aw_sent && response.r_valid;
      request.aw.addr = 32'h80000000;
      request.aw.size = 2;
      request.aw.burst = AXI4_BURST_INCR;
      request.w_valid = aw_sent && !w_sent;
      request.w.data = 32'hfedcba98;
      request.w.strb = 4'hf;
      request.w.last = 1;
      request.b_ready = 1;
    end
  end
  initial begin
    void'($value$plusargs("cpu_mhz=%d", mhz));
    void'($value$plusargs("latency_ns=%d", latency_ns));
    void'($value$plusargs("beat_ns=%d", beat_ns));
    void'($value$plusargs("burst_beats=%d", burst_beats));
    void'($value$plusargs("present_at=%d", present_at));
    void'($value$plusargs("accept_after=%d", accept_after));
    void'($value$plusargs("probe_stalls=%d", stalls));
    void'($value$plusargs("memory_mode=%s", mode));
    repeat (5) @(negedge clk);
    for (int i = 0; i < 16; i++) u_memory.words[i] = 32'h12340000 + 32'(i);
    rst_n = 1;
  end
  always @(posedge clk) if (rst_n) begin
    if (request.ar_valid && response.ar_ready) begin
      if (cycle != ((present_at > accept_after) ? present_at : accept_after))
        $fatal(1, "AR acceptance differs from declared schedule");
      accepted <= cycle;
    end
    if (accepted >= 0 && beats < burst_beats &&
        response.r_valid != (longint'(cycle) >= due_cycle))
      $fatal(1, "RVALID availability differs: cycle=%0d due=%0d", cycle, due_cycle);
    if (request.aw_valid && response.aw_ready) aw_sent <= 1;
    if (request.w_valid && response.w_ready) w_sent <= 1;
    if (response.r_valid && request.r_ready) begin
      if (response.r.id != 4'hb || response.r.last != (beats == burst_beats - 1) ||
          response.r.resp != AXI4_RESP_OKAY || response.r.data != (32'h12340000 + 32'(beats)))
        $fatal(1, "Read burst identity/payload mismatch at beat %0d", beats);
      if (stalls == 0 && longint'(cycle) != due_cycle)
        $fatal(1, "Unstalled beat differs from exact cumulative deadline");
      $display("BEAT ar=%0d cycle=%0d index=%0d due=%0d", accepted, cycle, beats, due_cycle);
      previous <= cycle;
      beats <= beats + 1;
      if (response.r.last) begin
        if (stalls == 3 && (!w_sent || u_memory.words[0] != 32'hfedcba98))
          $fatal(1, "Concurrent write was not exercised");
        $display("PASS independent memory timing");
        $finish;
      end
    end
    cycle <= cycle + 1;
    if (cycle > 2000) $fatal(1, "probe timeout");
  end
endmodule
