// 同一下游 AR/R 时刻，仅改变请求 VALID 提前量；独立核对延迟换算的顺序性质。
module delayer_start_order_tb;
  reg clock = 0, reset = 1;
  always #5 clock = ~clock;
  integer cycle = 0;
  integer return_cycle [0:3];
  integer address_cycle [0:3];
  integer native_return_cycle [0:3];
  always @(posedge clock)
    if (reset) cycle <= 0;
    else cycle <= cycle + 1;

  for (genvar i = 0; i < 4; i++) begin : gen_case
    localparam integer START_CYCLE = 1 + (i % 2);
    localparam integer RATIO = i < 2 ? 1 : 6;
    reg address_done = 0, native_return_done = 0;
    wire request_valid = cycle >= START_CYCLE && !address_done;
    wire request_ready, response_valid, native_request_valid, native_response_ready;
    wire [31:0] response_data;
    wire native_response_valid = cycle >= 10 && address_done && !native_return_done;
    axi4_delayer #(.PROCESSOR_TO_DEVICE_FREQUENCY_RATIO_SCALED(64'(RATIO * 1024))) dut (
      .clock(clock), .reset(reset),
      .in_arvalid(request_valid), .in_arready(request_ready), .in_arid(4'h1),
      .in_araddr(32'ha0000000), .in_arlen(8'd0), .in_arsize(3'd2), .in_arburst(2'd1),
      .in_rready(1'b1), .in_rvalid(response_valid), .in_rdata(response_data),
      .in_awvalid(1'b0), .in_awid(4'd0), .in_awaddr(32'd0), .in_awlen(8'd0),
      .in_awsize(3'd2), .in_awburst(2'd1), .in_wvalid(1'b0), .in_wdata(32'd0),
      .in_wstrb(4'd0), .in_wlast(1'b0), .in_bready(1'b1),
      .out_arready(cycle >= 8), .out_arvalid(native_request_valid),
      .out_rvalid(native_response_valid), .out_rready(native_response_ready),
      .out_rid(4'h1), .out_rdata(32'h12345678), .out_rresp(2'd0), .out_rlast(1'b1),
      .out_awready(1'b1), .out_wready(1'b1),
      .out_bvalid(1'b0), .out_bid(4'd0), .out_bresp(2'd0)
    );
    always @(posedge clock) begin
      if (reset) begin
        address_done <= 0;
        native_return_done <= 0;
        return_cycle[i] <= -1;
        address_cycle[i] <= -1;
        native_return_cycle[i] <= -1;
      end else begin
        if (request_valid && request_ready) begin
          address_done <= 1;
          address_cycle[i] <= cycle;
        end
        if (native_response_valid && native_response_ready) begin
          native_return_done <= 1;
          native_return_cycle[i] <= cycle;
        end
        if (response_valid) begin
          if (response_data !== 32'h12345678 || return_cycle[i] != -1)
            $fatal(1, "Lost or repeated response");
          return_cycle[i] <= cycle;
        end
      end
    end
  end

  initial begin
    repeat (3) @(negedge clock);
    reset = 0;
    repeat (100) @(negedge clock);
    for (integer i = 0; i < 4; i++) begin
      $display("case=%0d ratio=%0d valid_start=%0d native_AR=%0d native_R=%0d upstream_R=%0d",
               i, i < 2 ? 1 : 6, 1+i%2, address_cycle[i], native_return_cycle[i], return_cycle[i]);
      if (address_cycle[i] != 8 || native_return_cycle[i] != 10 || return_cycle[i] < 0)
        $fatal(1, "Probe did not preserve native device timing");
    end
    if (return_cycle[0] != return_cycle[1] || return_cycle[2] - return_cycle[3] != 5)
      $fatal(1, "Unexpected request timing sensitivity");
    $display("PASS: ratio 6 makes earlier VALID return five cycles later despite identical native AR/R");
    $finish;
  end
endmodule
