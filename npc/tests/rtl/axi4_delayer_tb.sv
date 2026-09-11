`timescale 1ns/1ns

module axi4_delayer_tb #(
    parameter longint unsigned TEST_RATIO_SCALED = 2048
);

  localparam int READ_BEAT_COUNT = 16;

  logic clock;
  logic reset;

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

  integer cycle_count;
  integer read_transaction_start_cycle;
  integer write_transaction_start_cycle;
  integer downstream_read_response_cycle [0:READ_BEAT_COUNT-1];
  integer upstream_read_response_cycle [0:READ_BEAT_COUNT-1];
  integer downstream_read_response_count;
  integer upstream_read_response_count;
  integer downstream_write_response_cycle;
  integer upstream_write_response_cycle;

  axi4_delayer #(
      .PROCESSOR_TO_DEVICE_FREQUENCY_RATIO_SCALED(TEST_RATIO_SCALED),
      .FREQUENCY_RATIO_SCALE_SHIFT(10),
      .READ_RESPONSE_BUFFER_DEPTH(16),
      .READ_RESPONSE_BUFFER_ADDR_WIDTH(4)
  ) u_axi4_delayer (
      .*
  );

  initial begin
    clock = 1'b0;
    forever #1 clock = ~clock;
  end

  // 统一在时钟边沿记录可观察事件。所有比较使用同一个cycle_count基准，
  // 因此不会混入testbench驱动相位的半周期偏差。
  always @(posedge clock) begin
    if (reset) begin
      cycle_count                         = 0;
      read_transaction_start_cycle       = -1;
      write_transaction_start_cycle      = -1;
      downstream_read_response_count     = 0;
      upstream_read_response_count       = 0;
      downstream_write_response_cycle    = -1;
      upstream_write_response_cycle      = -1;
    end else begin
      if (in_arvalid && read_transaction_start_cycle < 0) begin
        read_transaction_start_cycle = cycle_count;
      end

      if (out_rvalid && out_rready) begin
        downstream_read_response_cycle[downstream_read_response_count] =
            cycle_count;
        downstream_read_response_count = downstream_read_response_count + 1;
      end

      if (in_rvalid && in_rready) begin
        assert (in_rid == 4'h9)
          else $fatal(1, "read response ID mismatch");
        assert (in_rdata == 32'h2000_0000 + upstream_read_response_count)
          else $fatal(1, "read response data mismatch at beat %0d",
                      upstream_read_response_count);
        assert (in_rresp == 2'b00)
          else $fatal(1, "read response status mismatch");
        assert (in_rlast ==
                (upstream_read_response_count == READ_BEAT_COUNT - 1))
          else $fatal(1, "read response LAST mismatch at beat %0d",
                      upstream_read_response_count);

        upstream_read_response_cycle[upstream_read_response_count] =
            cycle_count;
        upstream_read_response_count = upstream_read_response_count + 1;
      end

      if ((in_awvalid || in_wvalid) && write_transaction_start_cycle < 0) begin
        write_transaction_start_cycle = cycle_count;
      end

      if (out_bvalid && out_bready) begin
        downstream_write_response_cycle = cycle_count;
      end

      if (in_bvalid && in_bready) begin
        assert (in_bid == 4'h5)
          else $fatal(1, "write response ID mismatch");
        assert (in_bresp == 2'b10)
          else $fatal(1, "write response status mismatch");
        upstream_write_response_cycle = cycle_count;
      end

      cycle_count = cycle_count + 1;
    end
  end

  integer beat_index;
  integer expected_upstream_cycle;

  initial begin
    reset       = 1'b1;

    in_arvalid = 1'b0;
    in_arid    = 4'd0;
    in_araddr  = 32'd0;
    in_arlen   = 8'd0;
    in_arsize  = 3'd0;
    in_arburst = 2'd0;
    in_rready  = 1'b1;

    in_awvalid = 1'b0;
    in_awid    = 4'd0;
    in_awaddr  = 32'd0;
    in_awlen   = 8'd0;
    in_awsize  = 3'd0;
    in_awburst = 2'd0;
    in_wvalid  = 1'b0;
    in_wdata   = 32'd0;
    in_wstrb   = 4'd0;
    in_wlast   = 1'b0;
    in_bready  = 1'b1;

    out_arready = 1'b1;
    out_rvalid  = 1'b0;
    out_rid     = 4'd0;
    out_rdata   = 32'd0;
    out_rresp   = 2'd0;
    out_rlast   = 1'b0;

    out_awready = 1'b0;
    out_wready  = 1'b1;
    out_bvalid  = 1'b0;
    out_bid     = 4'd0;
    out_bresp   = 2'd0;

    repeat (4) @(posedge clock);
    @(negedge clock);
    reset = 1'b0;

    // ----------------------------------------------------------------------
    // 16-beat 读 burst：检查每个 beat 相对于请求起点的校准时间。
    // ----------------------------------------------------------------------
    in_arvalid = 1'b1;
    in_arid    = 4'h9;
    in_araddr  = 32'ha000_0000;
    in_arlen   = 8'(READ_BEAT_COUNT - 1);
    in_arsize  = 3'd2;
    in_arburst = 2'd1;

    do @(posedge clock); while (!in_arready);
    @(negedge clock);
    in_arvalid = 1'b0;

    fork
      begin : drive_read_response_burst
        repeat (2) @(negedge clock);
        for (beat_index = 0; beat_index < READ_BEAT_COUNT;
             beat_index = beat_index + 1) begin
          out_rvalid = 1'b1;
          out_rid    = 4'h9;
          out_rdata  = 32'h2000_0000 + beat_index;
          out_rresp  = 2'b00;
          out_rlast  = beat_index == READ_BEAT_COUNT - 1;

          do @(posedge clock); while (!out_rready);
          @(negedge clock);
        end
        out_rvalid = 1'b0;
        out_rlast  = 1'b0;

        while (upstream_read_response_count < READ_BEAT_COUNT) begin
          @(negedge clock);
        end
      end

      begin : drive_overlapping_write_transaction
        // 在读burst尚未完成时启动写事务，验证读写计时状态真正相互独立。
        repeat (4) @(negedge clock);
        in_awvalid = 1'b1;
        in_awid    = 4'h5;
        in_awaddr  = 32'ha000_0100;
        in_awlen   = 8'd0;
        in_awsize  = 3'd2;
        in_awburst = 2'd1;

        // W先于AW握手；事务起点仍应是更早出现的AWVALID。
        @(negedge clock);
        in_wvalid = 1'b1;
        in_wdata  = 32'h55aa_1234;
        in_wstrb  = 4'hf;
        in_wlast  = 1'b1;

        do @(posedge clock); while (!in_wready);
        @(negedge clock);
        in_wvalid = 1'b0;
        in_wlast  = 1'b0;

        repeat (2) @(negedge clock);
        out_awready = 1'b1;
        do @(posedge clock); while (!in_awready);
        @(negedge clock);
        in_awvalid  = 1'b0;
        out_awready = 1'b0;

        repeat (2) @(negedge clock);
        out_bvalid = 1'b1;
        out_bid    = 4'h5;
        out_bresp  = 2'b10;
        do @(posedge clock); while (!out_bready);
        @(negedge clock);
        out_bvalid = 1'b0;

        while (upstream_write_response_cycle < 0) begin
          @(negedge clock);
        end
      end
    join

    assert (downstream_read_response_count == READ_BEAT_COUNT)
      else $fatal(1, "downstream read response count mismatch");

    for (beat_index = 0; beat_index < READ_BEAT_COUNT;
         beat_index = beat_index + 1) begin
      expected_upstream_cycle =
          read_transaction_start_cycle +
          int'((TEST_RATIO_SCALED * 64'(downstream_read_response_cycle[beat_index] -
                                       read_transaction_start_cycle)) >> 10);
      assert (upstream_read_response_cycle[beat_index] ==
              expected_upstream_cycle)
        else $fatal(1,
                    "read beat %0d timing mismatch: downstream=%0d upstream=%0d expected=%0d",
                    beat_index,
                    downstream_read_response_cycle[beat_index],
                    upstream_read_response_cycle[beat_index],
                    expected_upstream_cycle);
    end

    expected_upstream_cycle =
        write_transaction_start_cycle +
        int'((TEST_RATIO_SCALED * 64'(downstream_write_response_cycle -
                                     write_transaction_start_cycle)) >> 10);
    assert (upstream_write_response_cycle == expected_upstream_cycle)
      else $fatal(1,
                  "write timing mismatch: downstream=%0d upstream=%0d expected=%0d",
                  downstream_write_response_cycle,
                  upstream_write_response_cycle,
                  expected_upstream_cycle);

    $display("axi4_delayer_tb: PASS");
    $finish;
  end

  initial begin
    #2000;
    $fatal(1,
           "axi4_delayer_tb timeout: downstream_r=%0d upstream_r=%0d fifo_count=%0d read_active=%0b downstream_b=%0d upstream_b=%0d write_active=%0b",
           downstream_read_response_count,
           upstream_read_response_count,
           u_axi4_delayer.read_response_count_q,
           u_axi4_delayer.read_transaction_active_q,
           downstream_write_response_cycle,
           upstream_write_response_cycle,
           u_axi4_delayer.write_transaction_active_q);
  end

endmodule
