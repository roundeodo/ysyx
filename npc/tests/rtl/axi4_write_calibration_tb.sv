`timescale 1ns / 1ns

module axi4_write_calibration_tb #(
    parameter longint RATIO_SCALED = 7168
);


  logic          clock;
  logic          reset;

  logic          in_arready;
  logic          in_arvalid;
  logic   [ 3:0] in_arid;
  logic   [31:0] in_araddr;
  logic   [ 7:0] in_arlen;
  logic   [ 2:0] in_arsize;
  logic   [ 1:0] in_arburst;
  logic          in_rready;
  logic          in_rvalid;
  logic   [ 3:0] in_rid;
  logic   [31:0] in_rdata;
  logic   [ 1:0] in_rresp;
  logic          in_rlast;

  logic          in_awready;
  logic          in_awvalid;
  logic   [ 3:0] in_awid;
  logic   [31:0] in_awaddr;
  logic   [ 7:0] in_awlen;
  logic   [ 2:0] in_awsize;
  logic   [ 1:0] in_awburst;
  logic          in_wready;
  logic          in_wvalid;
  logic   [31:0] in_wdata;
  logic   [ 3:0] in_wstrb;
  logic          in_wlast;
  logic          in_bready;
  logic          in_bvalid;
  logic   [ 3:0] in_bid;
  logic   [ 1:0] in_bresp;

  logic          out_arready;
  logic          out_arvalid;
  logic   [ 3:0] out_arid;
  logic   [31:0] out_araddr;
  logic   [ 7:0] out_arlen;
  logic   [ 2:0] out_arsize;
  logic   [ 1:0] out_arburst;
  logic          out_rready;
  logic          out_rvalid;
  logic   [ 3:0] out_rid;
  logic   [31:0] out_rdata;
  logic   [ 1:0] out_rresp;
  logic          out_rlast;

  logic          out_awready;
  logic          out_awvalid;
  logic   [ 3:0] out_awid;
  logic   [31:0] out_awaddr;
  logic   [ 7:0] out_awlen;
  logic   [ 2:0] out_awsize;
  logic   [ 1:0] out_awburst;
  logic          out_wready;
  logic          out_wvalid;
  logic   [31:0] out_wdata;
  logic   [ 3:0] out_wstrb;
  logic          out_wlast;
  logic          out_bready;
  logic          out_bvalid;
  logic   [ 3:0] out_bid;
  logic   [ 1:0] out_bresp;

  wire device_clock_o;
  axi4_delayer #(
      .DEVICE_TIMING_MODE(0),      .PROCESSOR_TO_DEVICE_FREQUENCY_RATIO_SCALED(RATIO_SCALED),
      .FREQUENCY_RATIO_SCALE_SHIFT(10),
      .READ_RESPONSE_BUFFER_DEPTH(16),
      .READ_RESPONSE_BUFFER_ADDR_WIDTH(4)
  ) u_axi4_delayer (
      .*
  );


  initial begin
    clock = 0;
    forever #1 clock = ~clock;
  end
  integer cycle = 0;
  integer start_cycle = -1;
  integer first_valid_cycle = -1;
  integer downstream_words = 0;
  integer upstream_words = 0;
  integer last_word_cycle = -1;
  integer b_cycle = -1;
  integer b_valid_cycle = -1;
  integer gap_cycles = 0;
  integer initial_gap_cycles = 1;
  integer device_stall_cycles = 0;
  integer response_stall_cycles = 0;
  integer device_wait_count = 0;
  longint expected_cycle;
  longint response_deadline;

  // Independent reference: each device beat takes (stall+1) device cycles;
  // source gaps cost CPU cycles once. Two device cycles precede B generation.
  always @(posedge clock) begin
    if (reset) cycle = 0;
    else begin
      if (in_awvalid && start_cycle < 0) start_cycle = cycle;
      if (in_wvalid && first_valid_cycle < 0) first_valid_cycle = cycle;
      if (out_wvalid && out_wready) begin
        assert (out_wdata == 32'h12340000 + downstream_words &&
                out_wstrb == 4'hf && out_wlast == (downstream_words == 7))
        else $fatal(1, "W payload/order/duplicate error");
        if (out_wlast) last_word_cycle = cycle;
        downstream_words++;
      end
      if (in_wvalid && in_wready) begin
        expected_cycle = first_valid_cycle - 1 + gap_cycles * upstream_words +
            (((upstream_words + 1) * (device_stall_cycles + 1) * RATIO_SCALED) / 1024);
        assert (cycle == expected_cycle)
        else $fatal(1, "W beat %0d at %0d, expected %0d", upstream_words, cycle, expected_cycle);
        upstream_words++;
      end
      response_deadline = first_valid_cycle - 1 + gap_cycles * 7 +
          (((8 * (device_stall_cycles + 1) + 2) * RATIO_SCALED) / 1024);
      if (in_bvalid) begin
        if (b_valid_cycle < 0) b_valid_cycle = cycle;
        assert (b_valid_cycle == response_deadline && upstream_words == 8 && downstream_words == 8)
        else $fatal(1, "B first valid %0d expected %0d or missing W", b_valid_cycle, response_deadline);
        assert (in_bid == 5 && in_bresp == 0)
        else $fatal(1, "B payload changed under backpressure");
      end
      if (in_bvalid && in_bready) b_cycle = cycle;
      cycle++;
    end
  end

  // Model a device that applies a known number of READY-low cycles to every W.
  assign out_wready = (device_wait_count == device_stall_cycles);
  always @(posedge clock) begin
    if (reset || !out_wvalid || out_wready) begin
      device_wait_count <= 0;
    end else begin
      device_wait_count <= device_wait_count + 1;
    end
  end

  initial begin
    void'($value$plusargs("CPU_GAP=%d", gap_cycles));
    void'($value$plusargs("INITIAL_GAP=%d", initial_gap_cycles));
    void'($value$plusargs("DEVICE_STALL=%d", device_stall_cycles));
    void'($value$plusargs("B_STALL=%d", response_stall_cycles));
    reset = 1;
    in_arvalid = 0; in_arid = 0; in_araddr = 0; in_arlen = 0;
    in_arsize = 2; in_arburst = 1; in_rready = 1;
    out_arready = 1; out_rvalid = 0; out_rid = 0; out_rdata = 0;
    out_rresp = 0; out_rlast = 0;
    in_awvalid = 0; in_awid = 5; in_awaddr = 32'ha0000000;
    in_awlen = 7; in_awsize = 2; in_awburst = 1;
    in_wvalid = 0; in_wdata = 0; in_wstrb = 15; in_wlast = 0;
    in_bready = (response_stall_cycles == 0);
    out_awready = 1; out_bvalid = 0; out_bid = 5; out_bresp = 0;
    repeat (3) @(negedge clock);
    reset = 0;
    in_awvalid = 1;
    @(negedge clock);
    in_awvalid = 0;
    repeat (initial_gap_cycles) @(negedge clock);
    fork
      begin
        for (integer i = 0; i < 8; i++) begin
          in_wvalid = 1;
          in_wdata = 32'h12340000 + i;
          in_wlast = (i == 7);
          do @(posedge clock); while (!in_wready);
          @(negedge clock);
          in_wvalid = 0;
          if (i < 7) repeat (gap_cycles) @(negedge clock);
        end
        in_wlast = 0;
      end
      begin
        wait (last_word_cycle >= 0);
        @(negedge clock);
        @(negedge clock);
        out_bvalid = 1;
        do @(posedge clock); while (!out_bready);
        @(negedge clock);
        out_bvalid = 0;
      end
      begin
        wait (b_valid_cycle >= 0);
        repeat (response_stall_cycles) @(negedge clock);
        in_bready = 1;
      end
    join
    wait (b_cycle >= 0);
    @(negedge clock);
    assert (downstream_words == 8 && upstream_words == 8);
    $display("PASS ratio=%0d/1024 initial_gap=%0d gap=%0d device_stall=%0d b_stall=%0d BVALID=%0d",
             RATIO_SCALED, initial_gap_cycles, gap_cycles, device_stall_cycles, response_stall_cycles, b_valid_cycle);
    $finish;
  end
  initial begin
    #10000;
    $fatal(1, "write calibration timeout");
  end
endmodule
