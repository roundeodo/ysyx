// Compare first VALID at cycle 1 and 8 with identical AR acceptance at cycle 10.
module exploration_memory_probe_tb;
  import riscv32_axi4_pkg::*;
  logic clk = 0, rst_n = 0, result_valid;
  logic [31:0] result;
  always #5 clk = ~clk;
  axi4_manager_to_target_t request;
  axi4_target_to_manager_t response;
  int cycle = 0, present_at = 1, accepted = -1, previous_beat = -1, beats = 0;
  exploration_axi_memory u_memory (
      .clk_i(clk), .rst_ni(rst_n), .request_i(request), .response_o(response),
      .result_valid_o(result_valid), .result_o(result));
  always_comb begin
    request = '0;
    request.ar_valid = cycle >= present_at && accepted < 0;
    request.ar.addr = 32'h80000000;
    request.ar.len = 3;
    request.ar.size = 2;
    request.ar.burst = AXI4_BURST_INCR;
    request.r_ready = 1;
  end
  initial begin
    void'($value$plusargs("present_at=%d", present_at));
    repeat (5) @(negedge clk);
    rst_n = 1;
  end
  always @(posedge clk) if (rst_n) begin
    if (request.ar_valid && response.ar_ready) accepted <= cycle;
    if (response.r_valid && request.r_ready) begin
      if (beats == 0 && cycle-accepted != u_memory.first_cycles)
        $fatal(1, "first-beat service time differs from contract");
      if (beats != 0 && cycle-previous_beat != u_memory.beat_cycles)
        $fatal(1, "inter-beat service time differs from contract");
      $display("BEAT ar=%0d cycle=%0d index=%0d", accepted, cycle, beats);
      previous_beat = cycle;
      beats++;
      if (response.r.last) begin
        if (accepted != 10 || beats != 4) $fatal(1, "probe handshake schedule mismatch");
        $display("PASS memory service probe");
        $finish;
      end
    end
    cycle <= cycle+1;
    if (cycle > 1000) $fatal(1, "probe timeout");
  end
endmodule
