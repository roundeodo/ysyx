`timescale 1ns / 1ns
module device_clock_axi_stress_tb #(
    parameter integer CPU_MHZ = 720
);
  logic        clock;
  logic        reset;

  logic        in_arready;
  logic        in_arvalid;
  logic [ 3:0] in_arid;
  logic [31:0] in_araddr;
  logic [ 7:0] in_arlen;
  logic [ 2:0] in_arsize;
  logic [ 1:0] in_arburst;
  logic        in_rready;
  logic        in_rvalid;
  logic [ 3:0] in_rid;
  logic [31:0] in_rdata;
  logic [ 1:0] in_rresp;
  logic        in_rlast;

  logic        in_awready;
  logic        in_awvalid;
  logic [ 3:0] in_awid;
  logic [31:0] in_awaddr;
  logic [ 7:0] in_awlen;
  logic [ 2:0] in_awsize;
  logic [ 1:0] in_awburst;
  logic        in_wready;
  logic        in_wvalid;
  logic [31:0] in_wdata;
  logic [ 3:0] in_wstrb;
  logic        in_wlast;
  logic        in_bready;
  logic        in_bvalid;
  logic [ 3:0] in_bid;
  logic [ 1:0] in_bresp;

  logic        out_arready;
  logic        out_arvalid;
  logic [ 3:0] out_arid;
  logic [31:0] out_araddr;
  logic [ 7:0] out_arlen;
  logic [ 2:0] out_arsize;
  logic [ 1:0] out_arburst;
  logic        out_rready;
  logic        out_rvalid;
  logic [ 3:0] out_rid;
  logic [31:0] out_rdata;
  logic [ 1:0] out_rresp;
  logic        out_rlast;

  logic        out_awready;
  logic        out_awvalid;
  logic [ 3:0] out_awid;
  logic [31:0] out_awaddr;
  logic [ 7:0] out_awlen;
  logic [ 2:0] out_awsize;
  logic [ 1:0] out_awburst;
  logic        out_wready;
  logic        out_wvalid;
  logic [31:0] out_wdata;
  logic [ 3:0] out_wstrb;
  logic        out_wlast;
  logic        out_bready;
  logic        out_bvalid;
  logic [ 3:0] out_bid;
  logic [ 1:0] out_bresp;


  wire         device_clock_o;
  axi4_delayer #(
      .CPU_FREQUENCY_HZ  (64'd1000000 * CPU_MHZ),
      .DEVICE_TIMING_MODE(1)
  ) dut (
      .*
  );
  initial begin
    clock = 0;
    forever #1 clock = ~clock;
  end
  integer cycle = 0, dev_cycle = 0, trial = 0, beats = 0, r_received = 0, w_received = 0;
  integer read_index_q = 0, write_index_q = 0, read_wait_q = 0, read_len_q = 0;
  integer b_received = 0, max_read_count = 0;
  logic [31:0] cpu_random_q = 32'h439ac217, device_random_q = 32'h38f107b1;
  logic read_busy_q = 0, aw_present_q = 0, wlast_present_q = 0;
  logic [3:0] read_id_q = 0, write_id_q = 0;
  logic [31:0] read_base_q = 0;
  logic r_stalled_q = 0, b_stalled_q = 0;
  logic [38:0] r_payload_q;
  logic [ 5:0] b_payload_q;
  assign out_arready = !read_busy_q && (device_random_q[0] || device_random_q[4]);
  assign out_rvalid = read_busy_q && read_wait_q == 0;
  assign out_rdata = read_base_q + read_index_q * 4;
  assign out_rid = read_id_q;
  assign out_rlast = read_index_q == read_len_q;
  assign out_rresp = read_index_q % 7 == 3 ? 2'b10 : 2'b00;
  assign out_awready = !aw_present_q && (device_random_q[1] || device_random_q[7]);
  assign out_wready = !wlast_present_q && (device_random_q[2] || device_random_q[9]);
  assign out_bvalid = aw_present_q && wlast_present_q;
  assign out_bid = write_id_q;
  assign out_bresp = 2'b10;

  always @(posedge device_clock_o) begin
    if (reset) begin
      dev_cycle <= 0;
      read_busy_q <= 0;
      aw_present_q <= 0;
      wlast_present_q <= 0;
      read_wait_q <= 0;
      read_index_q <= 0;
      write_index_q <= 0;
      w_received <= 0;
    end else begin
      dev_cycle <= dev_cycle + 1;
      device_random_q <= {
        device_random_q[30:0],
        device_random_q[31] ^ device_random_q[21] ^ device_random_q[1] ^ device_random_q[0]
      };
      if (out_arvalid && out_arready) begin
        read_busy_q <= 1;
        read_id_q <= out_arid;
        read_len_q <= out_arlen;
        read_base_q <= out_araddr;
        read_index_q <= 0;
        read_wait_q <= 2;
      end
      if (read_wait_q > 0) read_wait_q <= read_wait_q - 1;
      if (out_rvalid && out_rready) begin
        if (out_rlast) read_busy_q <= 0;
        else begin
          read_index_q <= read_index_q + 1;
          read_wait_q  <= dev_cycle % 3;
        end
      end
      if (out_awvalid && out_awready) begin
        aw_present_q <= 1;
        write_id_q   <= out_awid;
      end
      if (out_wvalid && out_wready) begin
        assert(out_wdata==32'h12340000+trial*256+write_index_q &&
               out_wlast==(write_index_q==beats-1) && out_wstrb==15)
        else $fatal(1, "W order/data/last mismatch trial %0d index %0d", trial, write_index_q);
        write_index_q <= write_index_q + 1;
        w_received <= w_received + 1;
        if (out_wlast) wlast_present_q <= 1;
      end
      if (out_bvalid && out_bready) begin
        aw_present_q <= 0;
        wlast_present_q <= 0;
        write_index_q <= 0;
      end
    end
  end
  always @(posedge clock) begin
    if (reset) begin
      cycle = 0;
      r_received = 0;
      b_received = 0;
      r_stalled_q = 0;
      b_stalled_q = 0;
    end else begin
      cycle++;
      cpu_random_q = {
        cpu_random_q[30:0], cpu_random_q[31] ^ cpu_random_q[21] ^ cpu_random_q[1] ^ cpu_random_q[0]
      };
      if (r_stalled_q)
        assert (in_rvalid && {in_rid, in_rdata, in_rresp, in_rlast} == r_payload_q)
        else $fatal(1, "R changed under CPU backpressure");
      if (b_stalled_q)
        assert (in_bvalid && {in_bid, in_bresp} == b_payload_q)
        else $fatal(1, "B changed under CPU backpressure");
      r_stalled_q = in_rvalid && !in_rready;
      r_payload_q = {in_rid, in_rdata, in_rresp, in_rlast};
      b_stalled_q = in_bvalid && !in_bready;
      b_payload_q = {in_bid, in_bresp};
      if (in_rvalid && in_rready) begin
        assert(in_rid==4'(trial+1) && in_rdata==32'ha0000000+trial*256+r_received*4 &&
               in_rresp==(r_received%7==3 ? 2 : 0) && in_rlast==(r_received==beats-1))
        else $fatal(1, "R order/data/id/error mismatch trial %0d index %0d", trial, r_received);
        r_received++;
      end
      if (in_bvalid && in_bready) begin
        assert (in_bid == 4'(trial + 3) && in_bresp == 2 && w_received == beats)
        else $fatal(1, "B before W completion or wrong payload");
        b_received++;
      end
      if (dut.g_device.read_count_q > max_read_count) max_read_count = dut.g_device.read_count_q;
    end
  end
  task automatic run_trial;
    begin
      @(negedge clock);
      r_received = 0;
      w_received = 0;
      b_received = 0;
      beats = (trial % 3 == 0) ? 32 : ((trial % 3 == 1) ? 8 : 1);
      in_arid = 4'(trial + 1);
      in_araddr = 32'ha0000000 + trial * 256;
      in_arlen = 8'(beats - 1);
      in_awid = 4'(trial + 3);
      in_awlen = 8'(beats - 1);
      in_rready = 0;
      in_bready = 0;
      fork
        begin
          repeat (trial % 5) @(negedge clock);
          in_arvalid = 1;
          do @(posedge clock); while (!in_arready);
          @(negedge clock);
          in_arvalid = 0;
        end
        begin
          repeat ((trial % 3) * 15) @(negedge clock);
          in_awvalid = 1;
          do @(posedge clock); while (!in_awready);
          @(negedge clock);
          in_awvalid = 0;
        end
        begin
          repeat ((2 - trial % 3) * 9) @(negedge clock);
          for (integer i = 0; i < beats; i++) begin
            in_wvalid = 1;
            in_wdata  = 32'h12340000 + trial * 256 + i;
            in_wlast  = (i == beats - 1);
            do @(posedge clock); while (!in_wready);
            @(negedge clock);
            in_wvalid = 0;
            repeat ((i + trial) % 5) @(negedge clock);
          end
          in_wlast = 0;
        end
        begin
          repeat (trial % 3 == 0 ? 1200 : 37) @(negedge clock);
          while (r_received < beats) begin
            in_rready = (cpu_random_q[0] || cpu_random_q[5]);
            @(negedge clock);
          end
          in_rready = 1;
        end
        begin
          repeat (67) @(negedge clock);
          in_bready = 1;
          wait (b_received == 1);
        end
      join
      assert (r_received == beats && w_received == beats && b_received == 1);
    end
  endtask
  initial begin
    reset = 1;
    in_arvalid = 0;
    in_awvalid = 0;
    in_wvalid = 0;
    in_wlast = 0;
    in_araddr = 0;
    in_awaddr = 32'ha0100000;
    in_arid = 0;
    in_awid = 0;
    in_arlen = 0;
    in_awlen = 0;
    in_arsize = 2;
    in_awsize = 2;
    in_arburst = 1;
    in_awburst = 1;
    in_wdata = 0;
    in_wstrb = 15;
    in_rready = 0;
    in_bready = 0;
    repeat (4) @(negedge clock);
    reset = 0;
    for (trial = 0; trial < 18; trial++) run_trial();
    // Reset with both a queued R burst and an unconsumed B response.
    @(negedge clock);
    beats = 1;
    r_received = 0;
    w_received = 0;
    b_received = 0;
    in_rready = 0;
    in_bready = 0;
    in_arid = 4'(trial + 1);
    in_araddr = 32'ha0000000 + trial * 256;
    in_arlen = 31;
    in_awid = 4'(trial + 3);
    in_awlen = 0;
    fork
      begin
        in_arvalid = 1;
        do @(posedge clock); while (!in_arready);
        @(negedge clock);
        in_arvalid = 0;
      end
      begin
        in_awvalid = 1;
        do @(posedge clock); while (!in_awready);
        @(negedge clock);
        in_awvalid = 0;
      end
      begin
        in_wvalid = 1;
        in_wdata  = 32'h12340000 + trial * 256;
        in_wlast  = 1;
        do @(posedge clock); while (!in_wready);
        @(negedge clock);
        in_wvalid = 0;
        in_wlast  = 0;
      end
    join
    repeat (600) @(negedge clock);
    assert (dut.g_device.read_count_q > 0 && in_bvalid)
    else $fatal(1, "reset scenario did not retain both responses");
    reset = 1;
    repeat (4) @(negedge clock);
    reset = 0;
    repeat (3) begin
      @(posedge clock);
      assert (!in_rvalid && !in_bvalid)
      else $fatal(1, "response survived reset");
    end
    run_trial();
    assert (max_read_count == 16)
    else $fatal(1, "R full-buffer scenario not reached");
    $display("PASS AXI cpu_mhz=%0d trials=19 reset_pending=1 max_read_queue=%0d", CPU_MHZ,
             max_read_count);
    $finish;
  end
  initial begin
    #500000;
    $fatal(1, "AXI stress timeout trial %0d", trial);
  end
endmodule
