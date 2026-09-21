// Real core and caches with unified AXI memory. Checks prediction repair, fatal clean,
// and a trap handler that reads a retired store after a failed dirty replacement.
module riscv32_fence_i_tb;
  import riscv32_pkg::*;
  import riscv32_axi4_pkg::*;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  axi4_manager_to_target_t instruction_request, data_request;
  axi4_target_to_manager_t instruction_response, data_response;
  riscv32_core #(
      .RESET_PC(32'h80000000)
  ) dut (
      .clk_i                     (clk),
      .rst_ni                    (rst_n),
      .timer_interrupt_i         (timer_interrupt),
      .instruction_axi4_manager_o(instruction_request),
      .instruction_axi4_manager_i(instruction_response),
      .data_axi4_manager_o       (data_request),
      .data_axi4_manager_i       (data_response)
  );
  logic [31:0] memory_words[512], sram = 32'h12345678;
  logic instruction_read_present = 0, data_read_present = 0, write_present = 0, write_complete = 0;
  axi4_read_address_t instruction_address, data_address;
  axi4_write_address_t write_address;
  int instruction_beat = 0, data_beat = 0, write_beat = 0;
  int write_response_delay = 0, instruction_read_delay = 0, data_read_delay = 0;
  int cycle = 0;
  int bad_writes = 0, good_writes = 0, fences = 0, post_site = 0;
  int decode_fault = 0;
  int clean_fault = 0, inject_prediction = 0, schedule = 0, partial_write = 0, memory_fault = 0;
  int sequential_recoveries = 0, traps = 0, stale_predictions = 0, first_failed_cycle = -1;
  logic                      timer_interrupt;
  logic               [31:0] patch_word;
  branch_prediction_t        injected_prediction;
  assign timer_interrupt = dut.fence_i_failed;
  // Deliberate predictor-output fault injection isolates the nonbranch recovery path.
  // Normal cases train the predictor exclusively by executing software.
  always_comb begin
    injected_prediction = '0;
    injected_prediction.predicted_taken = dut.u_branch_predictor.selected_taken;
    injected_prediction.predicted_target = dut.u_branch_predictor.selected_taken ?
        dut.u_branch_predictor.selected_target_pc : '0;
    if (fences != 0 && dut.next_pc_predictor_lookup_request_pc == 32'h80000080) begin
      injected_prediction.predicted_taken  = 1;
      injected_prediction.predicted_target = 32'h80000100;
    end
  end
  int dirty_mode = 0, dirty_fault_seen = 0, dirty_writebacks = 0;
  logic write_failure;
  assign write_failure = (clean_fault!=0 && write_address.addr>=32'h80000000) ||
      (dirty_mode!=0 && write_address.addr==32'h80000400 && dirty_fault_seen==0);
  string hex_file;
  function automatic logic [31:0] read_word(input logic [31:0] addr);
    if (addr >= 32'h80000000 && addr < 32'h80000800) return memory_words[(addr-32'h80000000)>>2];
    if (addr == 32'h0f000000) return sram;
    return 32'h00000013;
  endfunction
  always_comb begin
    instruction_response = '0;
    instruction_response.ar_ready = !instruction_read_present && ((cycle + schedule) % 4 != 1);
    instruction_response.r_valid = instruction_read_present && instruction_read_delay == 0;
    instruction_response.r.id = instruction_address.id;
    instruction_response.r.last = (instruction_beat == int'(instruction_address.len));
    instruction_response.r.resp = AXI4_RESP_OKAY;
    instruction_response.r.data = read_word(instruction_address.addr + 32'(instruction_beat * 4));
    data_response = '0;
    data_response.ar_ready = !data_read_present && ((cycle + schedule) % 3 != 1);
    data_response.r_valid = data_read_present && data_read_delay == 0;
    data_response.r.id = data_address.id;
    data_response.r.last = (data_beat == int'(data_address.len));
    data_response.r.resp=(memory_fault!=0 && data_address.addr==32'h0f000000) ? AXI4_RESP_SLVERR : AXI4_RESP_OKAY;
    data_response.r.data = read_word(data_address.addr + 32'(data_beat * 4));
    data_response.aw_ready = !write_present && ((cycle + schedule) % 5 != 1);
    data_response.w_ready = write_present && !write_complete && ((cycle + schedule) % 3 != 1);
    data_response.b_valid = write_present && write_complete && (write_response_delay == 0);
    data_response.b.id = write_address.id;
    data_response.b.resp=write_failure ? (clean_fault!=0 ? axi4_resp_e'(clean_fault) : AXI4_RESP_SLVERR) :
        ((memory_fault!=0 && write_address.addr==32'h0f000000) ? AXI4_RESP_SLVERR : AXI4_RESP_OKAY);
  end
  always @(posedge clk)
    if (rst_n) begin
      cycle <= cycle + 1;
      if (instruction_request.ar_valid && instruction_response.ar_ready) begin
        instruction_read_present <= 1;
        instruction_address      <= instruction_request.ar;
        instruction_beat         <= 0;
        instruction_read_delay   <= schedule * 2;
      end else if (instruction_read_delay > 0) instruction_read_delay <= instruction_read_delay - 1;
      if (instruction_response.r_valid && instruction_request.r_ready) begin
        if (instruction_response.r.last) instruction_read_present <= 0;
        else instruction_beat <= instruction_beat + 1;
      end
      if (data_request.ar_valid && data_response.ar_ready) begin
        data_read_present <= 1;
        data_address      <= data_request.ar;
        data_beat         <= 0;
        data_read_delay   <= schedule * 3;
      end else if (data_read_delay > 0) data_read_delay <= data_read_delay - 1;
      if (data_response.r_valid && data_request.r_ready) begin
        if (data_response.r.last) data_read_present <= 0;
        else data_beat <= data_beat + 1;
      end
      if (data_request.aw_valid && data_response.aw_ready) begin
        write_present  <= 1;
        write_address  <= data_request.aw;
        write_beat     <= 0;
        write_complete <= 0;
      end
      if (data_request.w_valid && data_response.w_ready) begin
        if(write_address.addr>=32'h80000000 && (!write_failure || (partial_write!=0 && write_beat<2))) begin
          for (int b = 0; b < 4; b++)
          if (data_request.w.strb[b])
            memory_words[((write_address.addr-32'h80000000)>>2)+write_beat][b*8+:8]<=data_request.w.data[b*8+:8];
        end
        if (write_address.addr == 32'h0f000000) sram <= data_request.w.data;
        if (write_address.addr == 32'h10002000) begin
          bad_writes <= bad_writes + 1;
          $display("OBSERVED wrong-target MMIO store cycle=%0d data=%h", cycle,
                   data_request.w.data);
        end
        if (write_address.addr == 32'h10002004) begin
          if (dirty_mode != 0 && data_request.w.data != 32'hdeadbeef)
            $fatal(1, "trap handler lost a retired store");
          good_writes <= good_writes + 1;
        end
        write_beat <= write_beat + 1;
        if (data_request.w.last) begin
          write_complete       <= 1;
          write_response_delay <= schedule * 7;
        end
      end else if (write_response_delay > 0) write_response_delay <= write_response_delay - 1;
      if (data_response.b_valid && data_request.b_ready) begin
        $display("B cycle=%0d addr=%h resp=%0d", cycle, write_address.addr, data_response.b.resp);
        if (dirty_mode != 0 && write_address.addr == 32'h80000400) begin
          dirty_fault_seen <= 1;
          dirty_writebacks <= dirty_writebacks + 1;
        end
        write_present  <= 0;
        write_complete <= 0;
      end
      if (dut.committed_fence_i_event) begin
        fences <= fences + 1;
        $display("FENCE commit cycle=%0d", cycle);
      end
      if (dut.fence_i_maintenance_active && dut.next_pc_predictor_lookup_request_valid)
        $fatal(1, "prediction query escaped maintenance");
      if(fences && dut.next_pc_predictor_lookup_request_valid && dut.next_pc_predictor_lookup_request_ready && dut.next_pc_predictor_lookup_request_pc==32'h80000080)
        $display(
            "QUERY A cycle=%0d maintenance=%b invalidate=%b",
            cycle,
            dut.fence_i_maintenance_active,
            dut.icache_invalidate_req
        );
      if(fences && dut.ifu_fetch_entry_valid && dut.ifu_fetch_entry_ready && dut.ifu_fetch_entry.pc==32'h80000080)
        $display(
            "FETCH A cycle=%0d instr=%h predicted_taken=%b target=%h",
            cycle,
            dut.ifu_fetch_entry.instruction,
            dut.ifu_fetch_entry.prediction.predicted_taken,
            dut.ifu_fetch_entry.prediction.predicted_target
        );
      if (dut.sequential_redirect_valid) sequential_recoveries <= sequential_recoveries + 1;
      if(dut.ifu_fetch_entry_valid && dut.ifu_fetch_entry_ready && fences!=0 &&
        dut.ifu_fetch_entry.pc==32'h80000080 && dut.ifu_fetch_entry.prediction.predicted_taken)
        stale_predictions <= stale_predictions + 1;
      if (dut.fence_i_failed && first_failed_cycle < 0) first_failed_cycle <= cycle;
      if(dut.fence_i_failed && (dut.commit_valid || dut.lsu_req_valid ||
        dut.icache_invalidate_req || dut.interrupt_valid || instruction_request.ar_valid))
        $fatal(1, "fatal maintenance resumed execution or interrupt");
      if (dut.icache_invalidate_req)
        $display("INVALIDATE cycle=%0d done=%b", cycle, dut.icache_invalidate_done);
      if (dut.commit_valid && (fences != 0 || dirty_mode != 0)) begin
        if (dut.commit.pc != 32'h800001c0)
          $display(
              "COMMIT cycle=%0d pc=%h next=%h trap=%b",
              cycle,
              dut.commit.pc,
              dut.commit.next_pc,
              dut.commit.trap_taken
          );
        if (dut.commit.trap_taken) begin
          if (dirty_mode == 0 && ((memory_fault == 0 && decode_fault == 0) || dut.commit.pc != 32'h80000080))
            $fatal(1, "unexpected trap");
          traps <= traps + 1;
        end
        if (post_site == 1) begin
          $display("SITE_SUCCESSOR actual=%h expected=80000084", dut.commit.pc);
          if (dut.commit.pc != 32'h80000084) $fatal(1, "nonbranch successor was not A+4");
          post_site <= 2;
        end
        if (dut.commit.pc == 32'h80000080 && !dut.commit.trap_taken) post_site <= 1;
      end
      if (cycle == 1500) begin
        $display("RESULT fences=%0d site=%0d wrong_target_stores=%0d correct_path_stores=%0d",
                 fences, post_site, bad_writes, good_writes);
        if (dirty_mode != 0) begin
          if (traps != 1 || dirty_writebacks != 2 || good_writes != 1 || bad_writes != 0)
            $fatal(1, "dirty replacement trap/retry did not preserve retired stores");
          $display("PASS retired-store preservation across trap and retry");
        end else begin
          if (fences != 1 || bad_writes != 0)
            $fatal(1, "fence count or wrong-path MMIO side effect");
          if (clean_fault != 0) begin
            if(first_failed_cycle<0 || cycle-first_failed_cycle<200 || post_site!=0 || good_writes!=0)
              $fatal(1, "clean failure did not remain halted");
          end else if (memory_fault != 0 || decode_fault != 0) begin
            if (traps != 1 || post_site != 0 || good_writes != 0)
              $fatal(1, "memory exception escaped recovery");
          end else begin
            if (post_site != 2 || good_writes != 1 || traps != 0)
              $fatal(1, "missing sequential completion");
          end
          if(clean_fault==0 && inject_prediction!=0 && (stale_predictions!=1 ||
          (decode_fault==0 && patch_word!=32'h0040006f && sequential_recoveries==0)))
            $fatal(1, "injected stale prediction did not exercise recovery");
          $display(
              "PASS fence recovery: injection=%0d clean_error=%0d memory_error=%0d schedule=%0d",
              inject_prediction, clean_fault, memory_fault, schedule);
        end
        $finish;
      end
    end
  initial begin
    for (int i = 0; i < 512; i++) memory_words[i] = 32'h00000013;
    if (!$value$plusargs("hex=%s", hex_file)) $fatal(1, "missing hex");
    void'($value$plusargs("decode_fault=%d", decode_fault));
    void'($value$plusargs("clean_fault=%d", clean_fault));
    void'($value$plusargs("dirty_mode=%d", dirty_mode));
    void'($value$plusargs("inject=%d", inject_prediction));
    void'($value$plusargs("schedule=%d", schedule));
    void'($value$plusargs("partial=%d", partial_write));
    void'($value$plusargs("memory_fault=%d", memory_fault));
    if (!$value$plusargs("patch_word=%h", patch_word)) $fatal(1, "missing patch opcode");
    if (inject_prediction != 0)
      force dut.u_branch_predictor.selected_prediction = injected_prediction;
    $readmemh(hex_file, memory_words);
    repeat (4) @(negedge clk);
    rst_n = 1;
  end
endmodule
