// Real core and caches; unified AXI RAM. Software trains, patches and fences.
module fence_probe_tb;
  import riscv32_pkg::*;
  import riscv32_axi4_pkg::*;
  logic clk=0, rst_n=0;
  always #5 clk=~clk;
  axi4_manager_to_target_t iq,dq;
  axi4_target_to_manager_t ir,dr;
  riscv32_core #(.RESET_PC(32'h80000000)) dut(
    .clk_i(clk), .rst_ni(rst_n), .timer_interrupt_i(1'b0),
    .instruction_axi4_manager_o(iq), .instruction_axi4_manager_i(ir),
    .data_axi4_manager_o(dq), .data_axi4_manager_i(dr));
  logic [31:0] ram[512], sram=32'h12345678;
  logic ip=0,dp=0,wp=0,wdone=0;
  axi4_read_address_t ia,da;
  axi4_write_address_t wa;
  int ib=0,db=0,wb=0,bdelay=0,cycle=0;
  int bad_writes=0,good_writes=0,fences=0,post_site=0;
  int clean_fault=0;
  string hex_file;
  function automatic logic[31:0] read_word(input logic[31:0] addr);
    if(addr>=32'h80000000 && addr<32'h80000800)
      return ram[(addr-32'h80000000)>>2];
    if(addr==32'h0f000000) return sram;
    return 32'h00000013;
  endfunction
  always_comb begin
    ir='0; ir.ar_ready=!ip; ir.r_valid=ip;
    ir.r.id=ia.id; ir.r.last=(ib==int'(ia.len));
    ir.r.resp=AXI4_RESP_OKAY; ir.r.data=read_word(ia.addr+32'(ib*4));
    dr='0; dr.ar_ready=!dp; dr.r_valid=dp;
    dr.r.id=da.id; dr.r.last=(db==int'(da.len));
    dr.r.resp=AXI4_RESP_OKAY; dr.r.data=read_word(da.addr+32'(db*4));
    dr.aw_ready=!wp; dr.w_ready=wp&&!wdone;
    dr.b_valid=wp&&wdone&&(bdelay==0); dr.b.id=wa.id;
    dr.b.resp=(clean_fault && wa.addr>=32'h80000000) ? AXI4_RESP_SLVERR : AXI4_RESP_OKAY;
  end
  always @(posedge clk) if(rst_n) begin
    cycle<=cycle+1;
    if(iq.ar_valid && ir.ar_ready) begin ip<=1; ia<=iq.ar; ib<=0; end
    if(ir.r_valid && iq.r_ready) begin
      if(ir.r.last) ip<=0; else ib<=ib+1;
    end
    if(dq.ar_valid && dr.ar_ready) begin dp<=1; da<=dq.ar; db<=0; end
    if(dr.r_valid && dq.r_ready) begin
      if(dr.r.last) dp<=0; else db<=db+1;
    end
    if(dq.aw_valid && dr.aw_ready) begin wp<=1; wa<=dq.aw; wb<=0; wdone<=0; end
    if(dq.w_valid && dr.w_ready) begin
      if(wa.addr>=32'h80000000 && !clean_fault) begin
        for(int b=0;b<4;b++) if(dq.w.strb[b])
          ram[((wa.addr-32'h80000000)>>2)+wb][b*8+:8]<=dq.w.data[b*8+:8];
      end
      if(wa.addr==32'h0f000000) sram<=dq.w.data;
      if(wa.addr==32'h10002000) begin
        bad_writes<=bad_writes+1;
        $display("OBSERVED wrong-target MMIO store cycle=%0d data=%h",cycle,dq.w.data);
      end
      if(wa.addr==32'h10002004) good_writes<=good_writes+1;
      wb<=wb+1;
      if(dq.w.last) begin wdone<=1; bdelay<=8; end
    end else if(bdelay>0) bdelay<=bdelay-1;
    if(dr.b_valid && dq.b_ready) begin
      $display("B cycle=%0d addr=%h resp=%0d",cycle,wa.addr,dr.b.resp);
      wp<=0; wdone<=0;
    end
    if(dut.committed_fence_i_event) begin
      fences<=fences+1;
      $display("FENCE commit cycle=%0d",cycle);
    end
    if(fences && dut.next_pc_predictor_lookup_request_valid && dut.next_pc_predictor_lookup_request_ready && dut.next_pc_predictor_lookup_request_pc==32'h80000080)
      $display("QUERY A cycle=%0d maintenance=%b invalidate=%b",cycle,dut.fence_i_maintenance_active,dut.icache_invalidate_req);
    if(fences && dut.ifu_fetch_entry_valid && dut.ifu_fetch_entry_ready && dut.ifu_fetch_entry.pc==32'h80000080)
      $display("FETCH A cycle=%0d instr=%h predicted_taken=%b target=%h",cycle,dut.ifu_fetch_entry.instruction,dut.ifu_fetch_entry.prediction.predicted_taken,dut.ifu_fetch_entry.prediction.predicted_target);
    if(dut.icache_invalidate_req) $display("INVALIDATE cycle=%0d done=%b",cycle,dut.icache_invalidate_done);
    if(dut.commit_valid && fences) begin
      $display("COMMIT cycle=%0d pc=%h next=%h trap=%b",cycle,dut.commit.pc,dut.commit.next_pc,dut.commit.trap_taken);
      if(dut.commit.trap_taken) $fatal(1,"unexpected trap");
      if(post_site==1) begin
        $display("SITE_SUCCESSOR actual=%h expected=80000084",dut.commit.pc);
        post_site<=2;
      end
      if(dut.commit.pc==32'h80000080) post_site<=1;
    end
    if(cycle==600) begin
      $display("RESULT fences=%0d site=%0d wrong_target_stores=%0d correct_path_stores=%0d",fences,post_site,bad_writes,good_writes);
      if(fences!=1 || post_site!=2) $fatal(1,"scenario did not reach observation boundary");
      $finish;
    end
  end
  initial begin
    for(int i=0;i<512;i++) ram[i]=32'h00000013;
    if(!$value$plusargs("hex=%s",hex_file)) $fatal(1,"missing hex");
    if($value$plusargs("clean_fault=%d",clean_fault)) begin end
    $readmemh(hex_file,ram);
    repeat(4) @(negedge clk); rst_n=1;
  end
endmodule
