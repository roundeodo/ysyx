module riscv32_issue_window_tb;
  import riscv32_pkg::*;
  logic clk = 0;
  always #5 clk = !clk;
  logic rst_n = 0;
  logic commit_valid = 0;
  commit_t commit_packet = '0;
  logic issue = 0, execute_valid = 0, redirect = 0, lsu_busy = 0;
  logic result_blocked = 0, rr_valid = 0, raw_hazard = 0, serial_hazard = 0;
  icache_event_t icache_event = '0;
  dcache_event_t dcache_event = '0;
  riscv32_sim_issue_window_monitor dut (
    .clk_i(clk), .rst_ni(rst_n), .commit_valid_i(commit_valid), .commit_i(commit_packet),
    .issue_event_i(issue), .execute_valid_i(execute_valid), .redirect_event_i(redirect),
    .lsu_busy_i(lsu_busy), .execute_result_blocked_i(result_blocked),
    .register_read_valid_i(rr_valid), .raw_hazard_present_i(raw_hazard),
    .serializing_hazard_present_i(serial_hazard), .icache_event_i(icache_event),
    .dcache_event_i(dcache_event)
  );
  task automatic step;
    @(posedge clk); #1; @(negedge clk);
  endtask
  initial begin
    step(); rst_n = 1;
    // 非标记、异常及写 CSR 不得打开窗口。
    commit_valid = 1; commit_packet.instruction = 32'hb0001073;
    commit_packet.gpr_write = 1; step();
    assert (!dut.window_active_q) else $fatal(1, "CSR write opened window");
    commit_packet.instruction = 32'hb0002573;
    commit_packet.trap_taken = 1; step();
    assert (!dut.window_active_q) else $fatal(1, "trap opened window");
    commit_packet.trap_taken = 0; commit_packet.gpr_wdata = 100; issue = 1; step();
    commit_valid = 0; issue = 0; redirect = 1; lsu_busy = 1; step();
    redirect = 0; lsu_busy = 0; issue = 1; step(); // 结束恢复
    issue = 0; lsu_busy = 1; step();
    lsu_busy = 0; result_blocked = 1; step();
    result_blocked = 0; execute_valid = 1; step();
    execute_valid = 0; rr_valid = 1; raw_hazard = 1; step();
    raw_hazard = 0; serial_hazard = 1; step();
    rr_valid = 0; serial_hazard = 0; step();
    commit_valid = 1; commit_packet.gpr_wdata = 109; step();
    commit_valid = 0; step();
    assert (!dut.window_active_q && dut.window_count_q == 1 && dut.cycle_count_q == 9)
      else $fatal(1, "window count or boundary mismatch");
    foreach (dut.category_count_array_q[index]) begin
      assert (dut.category_count_array_q[index] == (index == 0 ? 2 : 1))
        else $fatal(1, "category %0d mismatch", index);
    end
    assert (dut.lsu_busy_cycle_count_q == 2 && dut.redirect_count_q == 1)
      else $fatal(1, "overlapping observations lost");
    $display("issue window monitor PASS"); $finish;
  end
endmodule
