// I-cache + AXI refill 集成测试：检查同步读、early restart、反压、错误和 invalidate。
module riscv32_icache_contract_tb;
  import riscv32_pkg::*;
  import riscv32_addr_map_pkg::*;
  import riscv32_axi4_pkg::*;
  logic clk=0, rst_n=0;
  always #5 clk=~clk;
  icache_lookup_req_t request;
  icache_lookup_resp_t response;
  logic request_valid=0, request_ready, response_valid, response_ready=0;
  logic invalidate=0, invalidate_done, busy;
  icache_refill_req_t refill_request;
  icache_refill_resp_t refill_response;
  logic refill_request_valid, refill_request_ready, refill_response_valid, refill_response_ready;
  axi4_manager_to_target_t manager;
  axi4_target_to_manager_t target;
  icache_event_t events;
  int response_count=0, address_count=0, checks=0;
  icache_lookup_resp_t last_response;

  riscv32_icache cache (
      .retired_valid_i(1'b0), .retired_pc_i('0),
      .clk_i(clk), .rst_ni(rst_n), .lookup_req_i(request), .lookup_req_valid_i(request_valid),
      .lookup_req_ready_o(request_ready), .lookup_resp_o(response),
      .lookup_resp_valid_o(response_valid), .lookup_resp_ready_i(response_ready),
      .invalidate_req_i(invalidate), .invalidate_done_o(invalidate_done), .cache_busy_o(busy),
      .refill_req_o(refill_request), .refill_req_valid_o(refill_request_valid),
      .refill_req_ready_i(refill_request_ready), .refill_resp_i(refill_response),
      .refill_resp_valid_i(refill_response_valid), .refill_resp_ready_o(refill_response_ready),
      .event_o(events)
  );
  riscv32_icache_axi adapter (
      .clk_i(clk), .rst_ni(rst_n), .refill_req_i(refill_request),
      .refill_req_valid_i(refill_request_valid), .refill_req_ready_o(refill_request_ready),
      .refill_resp_o(refill_response), .refill_resp_valid_o(refill_response_valid),
      .refill_resp_ready_i(refill_response_ready), .axi_manager_o(manager), .axi_manager_i(target)
  );
  always @(posedge clk) begin
    if (rst_n && response_valid && response_ready) begin
      response_count++;
      last_response=response;
    end
    if (rst_n && manager.ar_valid && target.ar_ready) address_count++;
  end

  function automatic icache_fetch_data_t memory_word(input phys_addr_t addr);
    return icache_fetch_data_t'(addr ^ 32'h12345678);
  endfunction

  task automatic issue(input phys_addr_t addr, input bit expect_miss_bypass=0);
    @(negedge clk);
    request='{fetch_addr:addr, frontend_tag:frontend_tag_t'(checks), fetch_epoch:fetch_epoch_t'(2)};
    request_valid=1;
    do begin @(posedge clk); end while (!request_ready);
    if (expect_miss_bypass) begin
      #1;
      assert(manager.ar_valid) else $fatal(1,"miss allocation inserted an AR wait cycle");
    end
    @(negedge clk); request_valid=0;
  endtask

  task automatic refill(input bit cacheable, input int fault_word=-1, input bit direct_response=0);
    axi4_read_address_t captured_address;
    int words, lane, critical, before_responses;
    phys_addr_t addr;
    while (!manager.ar_valid) @(negedge clk);
    captured_address=manager.ar;
    words=cacheable ? ICACHE_WORDS_PER_LINE : 1;
    critical=cacheable ? int'((request.fetch_addr/ICACHE_FETCH_BYTES)%ICACHE_WORDS_PER_LINE) : 0;
    before_responses=response_count;
    response_ready=direct_response;
    assert (int'(manager.ar.len)==words-1 && manager.ar.size==$clog2(ICACHE_FETCH_BYTES) &&
            manager.ar.burst==AXI4_BURST_INCR) else $fatal(1,"wrong refill burst geometry");
    repeat(3) begin
      @(negedge clk);
      assert(manager.ar_valid && manager.ar===captured_address) else $fatal(1,"AR changed under stall");
    end
    target.ar_ready=1;
    @(negedge clk); target.ar_ready=0;
    for(int beat=0; beat<words; beat++) begin
      repeat(beat%3+1) @(negedge clk);
      addr=phys_addr_t'(captured_address.addr + MEM_AXI_ADDR_WIDTH'(beat*ICACHE_FETCH_BYTES));
      lane=int'(addr % MEM_AXI_DATA_BYTE_COUNT)*8;
      target.r='0;
      target.r.id=captured_address.id;
      target.r.data=MEM_AXI_DATA_WIDTH'(memory_word(addr)) << lane;
      target.r.resp=(beat==fault_word) ? AXI4_RESP_SLVERR : AXI4_RESP_OKAY;
      target.r.last=beat==words-1;
      target.r_valid=1;
      if (direct_response && beat==critical) begin
        #1;
        assert(response_valid && response.fetch_addr==request.fetch_addr &&
               response.frontend_tag==request.frontend_tag && response.fetch_epoch==request.fetch_epoch &&
               response.access_fault==((fault_word>=0) && (fault_word<=critical)))
          else $fatal(1,"critical response did not bypass its empty buffer");
        assert(response.fetch_data==(response.access_fault ? '0 : memory_word(request.fetch_addr)))
          else $fatal(1,"direct critical response data mismatch");
      end
      do begin @(posedge clk); end while (!manager.r_ready);
      @(negedge clk); target.r_valid=0;
      if (beat<words-1) begin
        assert(!request_ready) else $fatal(1,"blocking cache opened lookup before last beat");
        if (beat==critical && fault_word<0 && !direct_response)
          assert(response_valid && response.fetch_data==memory_word(request.fetch_addr))
            else $fatal(1,"critical word did not restart before the last beat");
      end
    end
    if (direct_response) begin
      repeat(3) @(negedge clk);
      assert(response_count==before_responses+1 && !response_valid)
        else $fatal(1,"direct response was lost or repeated");
      response_ready=0;
      checks++;
    end
  endtask

  task automatic consume(input bit fault);
    icache_lookup_resp_t held;
    int before_count;
    while (!response_valid) @(negedge clk);
    held=response;
    assert (held.fetch_addr==request.fetch_addr && held.frontend_tag==request.frontend_tag &&
            held.fetch_epoch==request.fetch_epoch && held.access_fault==fault &&
            held.fetch_data==(fault ? '0 : memory_word(request.fetch_addr)))
      else $fatal(1,"cache response mismatch addr=%h data=%h fault=%b",held.fetch_addr,held.fetch_data,held.access_fault);
    repeat(4) begin
      @(negedge clk);
      assert(response_valid && response===held) else $fatal(1,"cache response changed while stalled");
    end
    before_count=response_count;
    response_ready=1;
    @(negedge clk); response_ready=0;
    assert(response_count==before_count+1) else $fatal(1,"response not consumed exactly once");
    checks++;
    repeat(2) @(negedge clk);
    assert(!response_valid) else $fatal(1,"duplicate cache response");
  endtask

  task automatic clear_cache;
    @(negedge clk); invalidate=1;
    #1;
    assert(invalidate_done && !request_ready)
      else $fatal(1,"idle invalidate inserted a metadata scan delay");
    while(!invalidate_done) begin
      @(negedge clk);
      assert(!request_ready) else $fatal(1,"lookup accepted during invalidate");
    end
    @(negedge clk); invalidate=0;
    repeat(2) @(negedge clk);
  endtask

  initial begin
    int before_addresses;
    phys_addr_t pc, other_pc;
    request='0; target='0;
    repeat(3) @(negedge clk); rst_n=1;
    // 首字、末字与单 word line 都有独立查询，检查整行安装后的同步 hit。
    pc=32'h80000100;
    issue(pc); refill(1); consume(0);
    before_addresses=address_count;
    issue(pc + phys_addr_t'((ICACHE_WORDS_PER_LINE-1)*ICACHE_FETCH_BYTES)); consume(0);
    assert(address_count==before_addresses) else $fatal(1,"installed line missed");
    // 同 set 的不同 tag：遍历超过 way 数的行，检查替换后数据与身份。
    for(int i=1; i<=ICACHE_WAY_COUNT+1; i++) begin
      other_pc=pc + phys_addr_t'(i*ICACHE_SET_COUNT*ICACHE_LINE_BYTES);
      issue(other_pc); refill(1); consume(0);
    end
    // 不可执行 MMIO 本地报错，不产生下层请求。
    before_addresses=address_count;
    issue(32'h10000000); consume(1);
    assert(address_count==before_addresses) else $fatal(1,"nonexecutable address reached AXI");
    // uncached 地址每次都到 AXI，偏移覆盖宽总线的不同 byte lane。
    repeat(2) begin issue(32'h0f000004); refill(0); consume(0); end
    // critical 自身错误不能安装；重试仍需 refill。
    clear_cache();
    issue(pc); refill(1,0); consume(1);
    issue(pc); refill(1); consume(0);
    if(ICACHE_WORDS_PER_LINE>1) begin
      // critical 之后报错：已经返回的指令有效，但整行不能安装。
      clear_cache(); issue(pc); refill(1,ICACHE_WORDS_PER_LINE-1); consume(0);
      issue(pc); refill(1); consume(0);
      // critical 之前报错：critical 响应报错，所有 beat 仍必须被排空。
      clear_cache();
      issue(pc+phys_addr_t'((ICACHE_WORDS_PER_LINE-1)*ICACHE_FETCH_BYTES));
      refill(1,0); consume(1);
    end
    // invalidate 应使此前命中行重新 miss。
    clear_cache(); issue(pc); refill(1); consume(0);
    clear_cache(); issue(pc,1); refill(1,-1,1);
    clear_cache(); issue(pc+phys_addr_t'((ICACHE_WORDS_PER_LINE-1)*ICACHE_FETCH_BYTES),1);
    refill(1,0,1);
    issue(32'h0f000004,1); refill(0,-1,1);
    // 正在 refill 或等待响应消费时不得提前宣告失效完成。
    clear_cache(); issue(pc,1);
    invalidate=1;
    refill(1);
    assert(!invalidate_done && !request_ready)
      else $fatal(1,"invalidate skipped a blocked old miss response");
    consume(0);
    #1; assert(invalidate_done) else $fatal(1,"drained invalidate did not finish");
    @(negedge clk); invalidate=0;
    issue(pc,1); refill(1); consume(0);
    $display("PASS I-cache contract: ways=%0d line=%0d checks=%0d AXI reads=%0d responses=%0d",
             ICACHE_WAY_COUNT,ICACHE_LINE_BYTES,checks,address_count,response_count);
    $finish;
  end
  initial begin #1000000; $fatal(1,"I-cache test timeout"); end
endmodule
