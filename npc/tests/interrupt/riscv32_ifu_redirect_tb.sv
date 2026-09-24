// 重定向到来时，旧 lookup 仍在等待 ready；稍后握手不能覆盖恢复 PC。
module riscv32_ifu_redirect_tb;
  import riscv32_pkg::*;
  logic clk = 0;
  logic rst_n = 0;
  always #5 clk = ~clk;
  redirect_req_t redirect;
  logic redirect_valid = 0;
  icache_lookup_req_t request;
  logic request_valid;
  logic request_ready = 0;
  icache_lookup_resp_t response;
  logic response_valid = 0;
  logic response_ready;
  logic fetch_valid;
  riscv32_ifu #(.PC_START(32'h8000_0000)) dut (
      .clk_i(clk), .rst_ni(rst_n), .redirect_req_i(redirect),
      .redirect_req_valid_i(redirect_valid), .icache_lookup_req_o(request),
      .icache_lookup_req_valid_o(request_valid), .icache_lookup_req_ready_i(request_ready),
      .icache_lookup_resp_i(response), .icache_lookup_resp_valid_i(response_valid),
      .icache_lookup_resp_ready_o(response_ready), .fetch_entry_o(),
      .fetch_entry_valid_o(fetch_valid), .fetch_entry_ready_i(1'b1)
  );
  initial begin
    redirect = '0;
    response = '0;
    repeat (3) @(negedge clk);
    rst_n = 1;
    @(negedge clk);
    assert (request_valid && request.fetch_addr == 32'h8000_0000)
      else $fatal(1, "missing initial lookup");
    response.fetch_addr = request.fetch_addr;
    response.frontend_tag = request.frontend_tag;
    response.fetch_epoch = request.fetch_epoch;
    redirect_valid = 1;
    redirect.target_pc = 32'h8000_1000;
    @(negedge clk);
    redirect.target_pc = 32'h8000_2000; // 再次重定向，最后一个目标必须保留。
    @(negedge clk);
    redirect_valid = 0;
    request_ready = 1;
    @(negedge clk);
    request_ready = 0;
    response_valid = 1;
    #1;
    assert (response_ready && !fetch_valid) else $fatal(1, "stale response not discarded");
    @(negedge clk);
    response_valid = 0;
    #1;
    assert (request_valid && request.fetch_addr == 32'h8000_2000)
      else $fatal(1, "redirect target overwritten by late lookup handshake: %h", request.fetch_addr);
    $display("PASS IFU redirect: backpressured lookup, consecutive redirects, late handshake, stale response drain");
    $finish;
  end
endmodule
