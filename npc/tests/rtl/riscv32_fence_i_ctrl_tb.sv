// Maintenance ordering, a pre-existing stalled lookup, fatal retention and reset.
module riscv32_fence_i_ctrl_tb;
  import riscv32_pkg::*;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  commit_t commit;
  logic commit_valid = 0, lookup_valid = 0, lookup_ready = 0, cache_busy = 0;
  logic clean_done = 0, clean_fault = 0, invalidate_done = 0;
  logic committed, active, memory_allowed, prediction_allowed, failed, clean, invalidate;
  redirect_req_t redirect;
  int            cases = 0;
  riscv32_fence_i_ctrl dut (
      .clk_i                           (clk),
      .rst_ni                          (rst_n),
      .commit_valid_i                  (commit_valid),
      .commit_i                        (commit),
      .icache_lookup_req_valid_i       (lookup_valid),
      .icache_lookup_req_ready_i       (lookup_ready),
      .icache_busy_i                   (cache_busy),
      .dcache_clean_done_i             (clean_done),
      .dcache_clean_access_fault_i     (clean_fault),
      .icache_invalidate_done_i        (invalidate_done),
      .committed_fence_i_event_o       (committed),
      .fence_i_redirect_req_o          (redirect),
      .fence_i_maintenance_active_o    (active),
      .frontend_memory_access_allowed_o(memory_allowed),
      .frontend_prediction_allowed_o   (prediction_allowed),
      .maintenance_failed_o            (failed),
      .dcache_clean_req_o              (clean),
      .icache_invalidate_req_o         (invalidate)
  );
  task automatic step;
    @(posedge clk);
    #1;
    @(negedge clk);
  endtask
  task automatic reset;
    rst_n           = 0;
    commit_valid    = 0;
    lookup_valid    = 0;
    lookup_ready    = 0;
    cache_busy      = 0;
    clean_done      = 0;
    clean_fault     = 0;
    invalidate_done = 0;
    step();
    rst_n = 1;
    step();
    assert (!failed && prediction_allowed && memory_allowed && !active)
    else $fatal(1, "reset did not release maintenance");
  endtask
  initial begin
    commit           = '0;
    commit.system_op = SYS_FENCE_I;
    commit.pc        = 32'h8000007c;
    commit.next_pc   = 32'h80000080;
    for (int stalls = 0; stalls < 5; stalls++) begin
      for (int error = 0; error < 2; error++) begin
        reset();
        lookup_valid = 1;
        lookup_ready = 0;
        cache_busy   = 1;
        step();  // The lookup was already presented before FENCE.I committed.
        commit_valid = 1;
        #1;
        assert (committed && redirect.target_pc == commit.next_pc && !prediction_allowed)
        else $fatal(1, "maintenance start was not atomic with redirect");
        step();
        commit_valid = 0;
        repeat (stalls + 1) begin
          #1;
          assert (active && memory_allowed && !clean && !prediction_allowed)
          else $fatal(1, "stalled lookup was withdrawn or clean started early");
          step();
        end
        lookup_ready = 1;
        step();
        lookup_valid = 0;
        repeat (stalls + 1) begin
          #1;
          assert (!memory_allowed && !clean && !prediction_allowed)
          else $fatal(1, "clean did not await the old cache transaction");
          step();
        end
        cache_busy = 0;
        step();
        assert (clean && !invalidate)
        else $fatal(1, "clean did not start after draining");
        repeat (stalls + 1) step();
        clean_done  = 1;
        clean_fault = (error != 0);
        step();
        clean_done  = 0;
        clean_fault = 0;
        if (error != 0) begin
          repeat (20) begin
            assert(failed && active && !clean && !invalidate && !memory_allowed && !prediction_allowed)
            else $fatal(1, "fatal state resumed maintenance or fetching");
            step();
          end
        end else begin
          assert (invalidate && !prediction_allowed)
          else $fatal(1, "missing invalidate");
          repeat (stalls + 1) step();
          invalidate_done = 1;
          step();
          invalidate_done = 0;
          assert (!active && prediction_allowed && !failed)
          else $fatal(1, "successful maintenance did not resume");
        end
        reset();
        cases++;
      end
    end
    $display("PASS FENCE.I controller: %0d cases", cases);
    $finish;
  end
  initial begin
    #100000;
    $fatal(1, "controller timeout");
  end
endmodule
