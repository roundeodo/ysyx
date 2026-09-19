// 仲裁器与路由器串联测试：最后响应和下一地址同拍，分别检查旧、新事务归属。
module riscv32_axi4_handoff_tb;
  import riscv32_axi4_pkg::*;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  axi4_manager_to_target_t instruction_req, data_req, merged_req, target_req[2];
  axi4_target_to_manager_t instruction_resp, data_resp, merged_resp, target_resp[2];
  riscv32_axi4_arbiter arbiter (
      .clk_i(clk), .rst_ni(rst_n),
      .instruction_manager_i(instruction_req), .instruction_manager_o(instruction_resp),
      .data_manager_i(data_req), .data_manager_o(data_resp),
      .downstream_manager_o(merged_req), .downstream_manager_i(merged_resp)
  );
  riscv32_axi4_router #(
      .TARGET_COUNT(2), .TARGET_ADDRESS_BASE_ARRAY('{32'h1000, 32'h2000}),
      .TARGET_ADDRESS_LAST_ARRAY('{32'h1fff, 32'h2fff})
  ) router (
      .clk_i(clk), .rst_ni(rst_n), .upstream_manager_i(merged_req),
      .upstream_manager_o(merged_resp), .target_manager_array_o(target_req),
      .target_manager_array_i(target_resp)
  );
  task automatic reset_bus;
    @(negedge clk);
    rst_n = 0;
    instruction_req = '0; data_req = '0;
    foreach (target_resp[i]) target_resp[i] = '0;
    repeat (2) @(negedge clk);
    rst_n = 1;
    foreach (target_resp[i]) begin
      target_resp[i].ar_ready = 1;
      target_resp[i].aw_ready = 1;
      target_resp[i].w_ready = 1;
    end
  endtask
  task automatic read_handoff(input int old_target, input int new_target, input bit stall_address);
    axi4_read_address_t held_address;
    reset_bus();
    instruction_req.ar = '{addr:32'h1000 + 32'(old_target)*32'h1000,
        id:4'h3, len:0, size:2, burst:AXI4_BURST_INCR};
    instruction_req.ar_valid = 1;
    @(posedge clk);
    assert (instruction_resp.ar_ready) else $fatal(1,"initial AR blocked");
    @(negedge clk);
    instruction_req.ar_valid = 0;
    data_req.ar = '{addr:32'h1004 + 32'(new_target)*32'h1000,
        id:4'h5, len:0, size:2, burst:AXI4_BURST_INCR};
    data_req.ar_valid = 1;
    target_resp[old_target].r = '{data:32'h11223344, id:4'h3, resp:AXI4_RESP_OKAY, last:1};
    target_resp[old_target].r_valid = 1;
    repeat (3) begin
      #1;
      assert (instruction_resp.r_valid && !data_resp.r_valid && !merged_req.ar_valid)
        else $fatal(1,"new AR bypassed an unconsumed old R");
      @(negedge clk);
    end
    instruction_req.r_ready = 1;
    target_resp[new_target].ar_ready = !stall_address;
    #1;
    assert (target_req[new_target].ar_valid && instruction_resp.r_valid && !data_resp.r_valid &&
            target_req[new_target].ar.addr == data_req.ar.addr)
      else $fatal(1,"read handoff mixed old response and new address");
    held_address = target_req[new_target].ar;
    @(posedge clk);
    @(negedge clk);
    target_resp[old_target].r_valid = 0;
    if (stall_address) begin
      repeat (3) begin
        #1;
        assert (target_req[new_target].ar_valid && target_req[new_target].ar == held_address)
          else $fatal(1,"blocked rollover AR changed");
        @(negedge clk);
      end
      target_resp[new_target].ar_ready = 1;
      @(posedge clk);
      @(negedge clk);
    end
    data_req.ar_valid = 0;
    data_req.r_ready = 1;
    target_resp[new_target].r = '{data:32'h55667788, id:4'h5, resp:AXI4_RESP_SLVERR, last:1};
    target_resp[new_target].r_valid = 1;
    #1;
    assert (data_resp.r_valid && !instruction_resp.r_valid && data_resp.r.id == 5 &&
            data_resp.r.data == 32'h55667788 && data_resp.r.resp == AXI4_RESP_SLVERR)
      else $fatal(1,"new read response routed to old requester");
    @(posedge clk);
    @(negedge clk);
    target_resp[new_target].r_valid = 0;
  endtask
  task automatic write_handoff(input bit stall_address);
    reset_bus();
    data_req.aw = '{addr:32'h1000, id:4'h7, len:0, size:2, burst:AXI4_BURST_INCR};
    data_req.aw_valid = 1;
    data_req.w = '{data:32'habcdef01, strb:'1, last:1};
    data_req.w_valid = 1;
    @(posedge clk);
    assert (data_resp.aw_ready && data_resp.w_ready) else $fatal(1,"initial AW/W blocked");
    @(negedge clk);
    data_req.aw = '{addr:32'h2000, id:4'h9, len:0, size:2, burst:AXI4_BURST_INCR};
    data_req.w.data = 32'h12345678;
    target_resp[0].b = '{id:4'h7, resp:AXI4_RESP_SLVERR};
    target_resp[0].b_valid = 1;
    #1;
    assert (data_resp.b_valid && !data_resp.aw_ready && !data_resp.w_ready)
      else $fatal(1,"write handoff occurred before B was consumed");
    @(negedge clk);
    data_req.b_ready = 1;
    target_resp[1].aw_ready = !stall_address;
    #1;
    assert (target_req[1].aw_valid && target_req[1].w_valid && data_resp.w_ready &&
            target_req[0].b_ready && data_resp.b.id == 7 && data_resp.b.resp == AXI4_RESP_SLVERR)
      else $fatal(1,"write handoff mixed targets");
    @(posedge clk);
    @(negedge clk);
    target_resp[0].b_valid = 0;
    data_req.w_valid = 0;
    if (stall_address) begin
      repeat (3) begin
        #1;
        assert (target_req[1].aw_valid && !target_req[1].w_valid)
          else $fatal(1,"rollover write duplicated an accepted W beat");
        @(negedge clk);
      end
      target_resp[1].aw_ready = 1;
      @(posedge clk);
      @(negedge clk);
    end
    data_req.aw_valid = 0;
    target_resp[1].b = '{id:4'h9, resp:AXI4_RESP_OKAY};
    target_resp[1].b_valid = 1;
    #1;
    assert (data_resp.b_valid && data_resp.b.id == 9)
      else $fatal(1,"new write response retained old target");
    @(posedge clk);
    @(negedge clk);
    target_resp[1].b_valid = 0;
  endtask
  initial begin
    for (int old_target=0; old_target<2; old_target++)
      for (int new_target=0; new_target<2; new_target++)
        for (int stall=0; stall<2; stall++)
          read_handoff(old_target,new_target,1'(stall));
    write_handoff(0); write_handoff(1);
    $display("PASS AXI handoff: 8 read cases, 2 write cases; stalls, old/new targets, errors");
    $finish;
  end
  initial begin #100000; $fatal(1,"AXI handoff timeout"); end
endmodule
