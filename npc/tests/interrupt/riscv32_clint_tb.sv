module riscv32_clint_tb;
  import riscv32_axi4_pkg::*;
  import riscv32_addr_map_pkg::*;
  logic clk = 0;
  logic rst_n = 0;
  always #5 clk = ~clk;
  axi4_manager_to_target_t request;
  axi4_target_to_manager_t response;
  logic timer_interrupt;
  // 在这组总线测试中避免自动计数干扰预期值；整核测试检查实际递增和到期。
  riscv32_axi4_clint #(
      .CLINT_CLOCK_FREQ_HZ    (1_000_000),
      .MTIME_INCREMENT_FREQ_HZ(1)
  ) dut (
      .clk_i            (clk),
      .rst_ni           (rst_n),
      .axi_target_i     (request),
      .axi_target_o     (response),
      .timer_interrupt_o(timer_interrupt)
  );

  task automatic write_register(input logic [31:0] address, input logic [31:0] data,
                                input logic [3:0] strobe = 4'hf, input logic [2:0] size = 3'd2,
                                input logic [7:0] length = 0,
                                input axi4_resp_e expected_response = AXI4_RESP_OKAY);
    int accepted_beats;
    accepted_beats = 0;
    // W 先于 AW 到达，target 可以反压，但不能丢失请求。
    @(negedge clk);
    request.w_valid = 1;
    request.w       = '{data: data, strb: strobe, last: (length == 0)};
    repeat (3) @(negedge clk);
    request.aw       = '{addr: address, id: 4'h9, len: length, size: size, burst: AXI4_BURST_INCR};
    request.aw_valid = 1;
    do begin
      @(posedge clk);
      if (response.w_ready) accepted_beats++;
    end while (!response.aw_ready);
    @(negedge clk);
    request.aw_valid = 0;
    for (int beat_index = accepted_beats; beat_index <= int'(length); beat_index++) begin
      request.w.last = (beat_index == int'(length));
      do @(posedge clk); while (!response.w_ready);
      @(negedge clk);
    end
    request.w_valid = 0;
    wait (response.b_valid);
    repeat (5) begin
      @(negedge clk);
      assert (response.b_valid && response.b.id == 9 && response.b.resp == expected_response)
      else $fatal(1, "write response mismatch addr=%h resp=%h", address, response.b.resp);
    end
    request.b_ready = 1;
    @(negedge clk);
    request.b_ready = 0;
  endtask

  task automatic read_register(input logic [31:0] address, input logic [31:0] expected_data,
                               input logic [2:0] size = 3'd2, input logic [7:0] length = 0,
                               input axi4_resp_e expected_response = AXI4_RESP_OKAY);
    @(negedge clk);
    request.ar       = '{addr: address, id: 4'h6, len: length, size: size, burst: AXI4_BURST_INCR};
    request.ar_valid = 1;
    do @(posedge clk); while (!response.ar_ready);
    @(negedge clk);
    request.ar_valid = 0;
    for (int beat_index = 0; beat_index <= int'(length); beat_index++) begin
      wait (response.r_valid);
      repeat (4) begin
        @(negedge clk);
        assert (response.r_valid && response.r.id == 6 && response.r.resp == expected_response &&
                response.r.last == (beat_index == int'(length)))
        else $fatal(1, "read response mismatch addr=%h", address);
        if (expected_response == AXI4_RESP_OKAY)
          assert (response.r.data == expected_data)
          else
            $fatal(
                1,
                "read data addr=%h expected=%h actual=%h",
                address,
                expected_data,
                response.r.data
            );
      end
      request.r_ready = 1;
      @(negedge clk);
      request.r_ready = 0;
    end
  endtask

  initial begin
    request = '0;
    repeat (4) @(negedge clk);
    rst_n = 1;
    assert (!timer_interrupt)
    else $fatal(1, "interrupt asserted after reset");
    read_register(CLINT_MTIMECMP_LOW_ADDR, '1);
    read_register(CLINT_MTIMECMP_HIGH_ADDR, '1);
    write_register(CLINT_MTIMECMP_HIGH_ADDR, 0);
    write_register(CLINT_MTIMECMP_LOW_ADDR, 10);
    write_register(CLINT_MTIME_LOW_ADDR, 9);
    assert (!timer_interrupt)
    else $fatal(1, "early interrupt");
    write_register(CLINT_MTIME_LOW_ADDR, 10);
    assert (timer_interrupt)
    else $fatal(1, "equality did not trigger interrupt");
    write_register(CLINT_MTIMECMP_LOW_ADDR, 11);
    assert (!timer_interrupt)
    else $fatal(1, "comparator update did not clear interrupt");

    write_register(CLINT_MTIMECMP_LOW_ADDR, 32'h1234_5678, 4'b0101);
    read_register(CLINT_MTIMECMP_LOW_ADDR, 32'h0034_0078);
    write_register(CLINT_MTIMECMP_LOW_ADDR, '1, 0);
    read_register(CLINT_MTIMECMP_LOW_ADDR, 32'h0034_0078);
    write_register(CLINT_MTIMECMP_LOW_ADDR + 1, '1, 15, 2, 0, AXI4_RESP_SLVERR);
    write_register(CLINT_MTIMECMP_LOW_ADDR, '1, 15, 1, 0, AXI4_RESP_SLVERR);
    write_register(CLINT_MTIMECMP_LOW_ADDR, '1, 15, 2, 2, AXI4_RESP_SLVERR);
    read_register(CLINT_MTIMECMP_LOW_ADDR, 32'h0034_0078);
    read_register(CLINT_BASE_ADDR + 32'h100, 0, 2, 0, AXI4_RESP_SLVERR);
    read_register(CLINT_MTIMECMP_LOW_ADDR, 0, 2, 2, AXI4_RESP_SLVERR);

    // 低字读取的快照跨后续 mtime 更新仍保持一致；下一次高字读返回实时值。
    write_register(CLINT_MTIME_HIGH_ADDR, 1);
    write_register(CLINT_MTIME_LOW_ADDR, '1);
    read_register(CLINT_MTIME_LOW_ADDR, '1);
    write_register(CLINT_MTIME_HIGH_ADDR, 2);
    write_register(CLINT_MTIME_LOW_ADDR, 0);
    read_register(CLINT_MTIME_HIGH_ADDR, 1);
    read_register(CLINT_MTIME_HIGH_ADDR, 2);

    // 比较是无符号 64 位运算，不能只比较低 32 位或按有符号数比较。
    write_register(CLINT_MTIMECMP_HIGH_ADDR, 32'h8000_0000);
    assert (!timer_interrupt)
    else $fatal(1, "signed comparison used for mtime");
    write_register(CLINT_MTIME_HIGH_ADDR, 32'h8000_0001);
    assert (timer_interrupt)
    else $fatal(1, "64-bit comparison failed");
    $display(
        "PASS CLINT: reset, equality, rearm, 64-bit compare, byte writes, W-before-AW, R/B backpressure, invalid access/bursts, mtime snapshot");
    $finish;
  end
  initial begin
    #200000;
    $fatal(1, "CLINT test timeout");
  end
endmodule
