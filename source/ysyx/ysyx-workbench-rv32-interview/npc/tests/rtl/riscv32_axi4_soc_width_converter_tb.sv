module riscv32_axi4_soc_width_converter_tb;
  import riscv32_pkg::*;
  import riscv32_axi4_pkg::*;
  import riscv32_ysyx_soc_axi4_pkg::*;
  import riscv32_addr_map_pkg::*;

  logic clk;
  logic rst_ni;

  axi4_manager_to_target_t          upstream_request;
  axi4_target_to_manager_t          upstream_response;
  ysyx_soc_axi4_manager_to_target_t downstream_request;
  ysyx_soc_axi4_target_to_manager_t downstream_response;

  riscv32_axi4_soc_width_converter u_width_converter (
      .clk_i               (clk),
      .rst_ni              (rst_ni),
      .upstream_manager_i  (upstream_request),
      .upstream_manager_o  (upstream_response),
      .downstream_manager_o(downstream_request),
      .downstream_manager_i(downstream_response)
  );

  always #5 clk = ~clk;

  task automatic accept_read_address(
      input axi4_addr_t address,
      input axi4_id_t   transaction_id,
      input logic [2:0] transfer_size,
      input logic [7:0] expected_downstream_length,
      input logic [2:0] expected_downstream_size
  );
    @(negedge clk);
    upstream_request.ar.addr  = address;
    upstream_request.ar.id    = transaction_id;
    upstream_request.ar.len   = 8'd0;
    upstream_request.ar.size  = transfer_size;
    upstream_request.ar.burst = AXI4_BURST_INCR;
    upstream_request.ar_valid = 1'b1;
    downstream_response.ar_ready = 1'b0;
    #1;
    assert (downstream_request.ar_valid && !upstream_response.ar_ready)
      else $fatal(1, "AR backpressure was not propagated");
    assert ((downstream_request.ar.addr == address) &&
            (downstream_request.ar.id == transaction_id) &&
            (downstream_request.ar.len == expected_downstream_length) &&
            (downstream_request.ar.size == expected_downstream_size))
      else $fatal(1, "Converted AR payload mismatch");

    downstream_response.ar_ready = 1'b1;
    #1;
    assert (upstream_response.ar_ready)
      else $fatal(1, "Upstream AR did not complete when downstream became ready");
    @(posedge clk);
    #1;
    upstream_request.ar_valid    = 1'b0;
    downstream_response.ar_ready = 1'b0;
  endtask

  task automatic return_write_response(
      input axi4_id_t   transaction_id,
      input axi4_resp_e response
  );
    @(negedge clk);
    downstream_response.b.id    = transaction_id;
    downstream_response.b.resp  = response;
    downstream_response.b_valid = 1'b1;
    upstream_request.b_ready    = 1'b0;
    #1;
    assert (upstream_response.b_valid &&
            (upstream_response.b.id == transaction_id) &&
            (upstream_response.b.resp == response) &&
            !downstream_request.b_ready)
      else $fatal(1, "B response or B backpressure mismatch");

    upstream_request.b_ready = 1'b1;
    #1;
    assert (downstream_request.b_ready)
      else $fatal(1, "BREADY was not propagated");
    @(posedge clk);
    #1;
    downstream_response.b_valid = 1'b0;
    upstream_request.b_ready    = 1'b0;
  endtask

  initial begin
    clk                 = 1'b0;
    rst_ni              = 1'b0;
    upstream_request    = '0;
    downstream_response = '0;

    repeat (2) @(posedge clk);
    @(negedge clk);
    rst_ni = 1'b1;

    // 32位窄读位于64位上游data bus的高lane。事务数量不变，只转换返回lane。
    accept_read_address(axi4_addr_t'(PSRAM_BASE_ADDR + 32'd4), axi4_id_t'(3),
                        3'd2, 8'd0, 3'd2);
    @(negedge clk);
    downstream_response.r.data  = 32'h89ab_cdef;
    downstream_response.r.id    = ysyx_soc_axi4_id_t'(3);
    downstream_response.r.resp  = AXI4_RESP_OKAY;
    downstream_response.r.last  = 1'b1;
    downstream_response.r_valid = 1'b1;
    upstream_request.r_ready    = 1'b0;
    #1;
    assert (upstream_response.r_valid &&
            (upstream_response.r.data == 64'h89ab_cdef_0000_0000) &&
            !downstream_request.r_ready)
      else $fatal(1, "Narrow read lane conversion mismatch");
    upstream_request.r_ready = 1'b1;
    @(posedge clk);
    #1;
    downstream_response.r_valid = 1'b0;
    upstream_request.r_ready    = 1'b0;

    // 64位普通存储器读转换成两个32位beat。第二拍SLVERR必须合并到唯一上游响应。
    accept_read_address(axi4_addr_t'(PSRAM_BASE_ADDR + 32'h10), axi4_id_t'(4),
                        3'd3, 8'd1, 3'd2);
    @(negedge clk);
    downstream_response.r.data  = 32'h7654_3210;
    downstream_response.r.id    = ysyx_soc_axi4_id_t'(4);
    downstream_response.r.resp  = AXI4_RESP_OKAY;
    downstream_response.r.last  = 1'b0;
    downstream_response.r_valid = 1'b1;
    #1;
    assert (downstream_request.r_ready && !upstream_response.r_valid)
      else $fatal(1, "First wide-read beat was not buffered locally");
    @(posedge clk);
    #1;
    downstream_response.r_valid = 1'b0;

    @(negedge clk);
    downstream_response.r.data  = 32'hfedc_ba98;
    downstream_response.r.resp  = AXI4_RESP_SLVERR;
    downstream_response.r.last  = 1'b1;
    downstream_response.r_valid = 1'b1;
    upstream_request.r_ready    = 1'b0;
    #1;
    assert (upstream_response.r_valid &&
            (upstream_response.r.data == 64'hfedc_ba98_7654_3210) &&
            (upstream_response.r.resp == AXI4_RESP_SLVERR) &&
            upstream_response.r.last && !downstream_request.r_ready)
      else $fatal(1, "Wide read merge or error aggregation mismatch");
    upstream_request.r_ready = 1'b1;
    @(posedge clk);
    #1;
    downstream_response.r_valid = 1'b0;
    upstream_request.r_ready    = 1'b0;

    // 64位MMIO读不允许拆分：本地返回DECERR，并且下游AR始终保持无效。
    @(negedge clk);
    upstream_request.ar.addr  = axi4_addr_t'(UART_BASE_ADDR);
    upstream_request.ar.id    = axi4_id_t'(6);
    upstream_request.ar.len   = 8'd0;
    upstream_request.ar.size  = 3'd3;
    upstream_request.ar.burst = AXI4_BURST_INCR;
    upstream_request.ar_valid = 1'b1;
    #1;
    assert (upstream_response.ar_ready && !downstream_request.ar_valid)
      else $fatal(1, "Wide MMIO read escaped to downstream AXI");
    @(posedge clk);
    #1;
    upstream_request.ar_valid = 1'b0;
    @(negedge clk);
    #1;
    assert (upstream_response.r_valid &&
            (upstream_response.r.id == axi4_id_t'(6)) &&
            (upstream_response.r.resp == AXI4_RESP_DECERR) &&
            !downstream_request.ar_valid)
      else $fatal(1, "Wide MMIO read did not return local DECERR");
    upstream_request.r_ready = 1'b1;
    @(posedge clk);
    #1;
    upstream_request.r_ready = 1'b0;

    // W先于AW到达，验证两个channel被独立接收。64位W随后拆成低、高两个32位beat。
    @(negedge clk);
    upstream_request.w.data  = 64'h0123_4567_89ab_cdef;
    upstream_request.w.strb  = 8'hff;
    upstream_request.w.last  = 1'b1;
    upstream_request.w_valid = 1'b1;
    #1;
    assert (upstream_response.w_ready)
      else $fatal(1, "W-before-AW was not accepted");
    @(posedge clk);
    #1;
    upstream_request.w_valid = 1'b0;

    @(negedge clk);
    upstream_request.aw.addr  = axi4_addr_t'(PSRAM_BASE_ADDR + 32'h20);
    upstream_request.aw.id    = axi4_id_t'(5);
    upstream_request.aw.len   = 8'd0;
    upstream_request.aw.size  = 3'd3;
    upstream_request.aw.burst = AXI4_BURST_INCR;
    upstream_request.aw_valid = 1'b1;
    #1;
    assert (upstream_response.aw_ready)
      else $fatal(1, "AW was not accepted after buffered W");
    @(posedge clk);
    #1;
    upstream_request.aw_valid = 1'b0;

    @(negedge clk);
    downstream_response.aw_ready = 1'b0;
    downstream_response.w_ready  = 1'b0;
    #1;
    assert (downstream_request.aw_valid &&
            (downstream_request.aw.len == 8'd1) &&
            (downstream_request.aw.size == 3'd2) &&
            downstream_request.w_valid &&
            (downstream_request.w.data == 32'h89ab_cdef) &&
            (downstream_request.w.strb == 4'hf) &&
            !downstream_request.w.last)
      else $fatal(1, "First wide-write beat mismatch");

    downstream_response.w_ready = 1'b1;
    @(posedge clk);
    #1;
    @(negedge clk);
    #1;
    assert (downstream_request.w_valid &&
            (downstream_request.w.data == 32'h0123_4567) &&
            (downstream_request.w.strb == 4'hf) &&
            downstream_request.w.last && downstream_request.aw_valid)
      else $fatal(1, "Second wide-write beat mismatch");
    downstream_response.aw_ready = 1'b1;
    @(posedge clk);
    #1;
    downstream_response.aw_ready = 1'b0;
    downstream_response.w_ready  = 1'b0;

    return_write_response(axi4_id_t'(5), AXI4_RESP_OKAY);

    // 64位MMIO写同样只在本地消费AW/W并返回DECERR。
    @(negedge clk);
    upstream_request.aw.addr  = axi4_addr_t'(UART_BASE_ADDR);
    upstream_request.aw.id    = axi4_id_t'(7);
    upstream_request.aw.len   = 8'd0;
    upstream_request.aw.size  = 3'd3;
    upstream_request.aw.burst = AXI4_BURST_INCR;
    upstream_request.aw_valid = 1'b1;
    upstream_request.w.data   = 64'h1122_3344_5566_7788;
    upstream_request.w.strb   = 8'hff;
    upstream_request.w.last   = 1'b1;
    upstream_request.w_valid  = 1'b1;
    #1;
    assert (upstream_response.aw_ready && upstream_response.w_ready &&
            !downstream_request.aw_valid && !downstream_request.w_valid)
      else $fatal(1, "Wide MMIO write escaped to downstream AXI");
    @(posedge clk);
    #1;
    upstream_request.aw_valid = 1'b0;
    upstream_request.w_valid  = 1'b0;

    // 一个周期消费已缓冲的WLAST，下一周期产生唯一B响应。
    @(posedge clk);
    #1;
    @(negedge clk);
    #1;
    assert (upstream_response.b_valid &&
            (upstream_response.b.id == axi4_id_t'(7)) &&
            (upstream_response.b.resp == AXI4_RESP_DECERR) &&
            !downstream_request.aw_valid && !downstream_request.w_valid)
      else $fatal(1, "Wide MMIO write did not return local DECERR");
    upstream_request.b_ready = 1'b1;
    @(posedge clk);
    #1;

    $display("AXI64-to-ysyxSoC-AXI32 width converter test passed");
    $finish;
  end

endmodule : riscv32_axi4_soc_width_converter_tb
