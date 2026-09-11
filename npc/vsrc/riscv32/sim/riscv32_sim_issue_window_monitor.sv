`ifdef VERILATOR
// MicroBench 专用观察窗口；窗口与分类限制见硬件优化设计记录。
module riscv32_sim_issue_window_monitor
  import riscv32_pkg::*;
(
    input logic          clk_i,
    input logic          rst_ni,
    input logic          commit_valid_i,
    input commit_t       commit_i,
    input logic          issue_occurred_i,
    input logic          execute_valid_i,
    input logic          redirect_occurred_i,
    input logic          lsu_busy_i,
    input logic          execute_result_blocked_i,
    input logic          register_read_valid_i,
    input logic          raw_hazard_present_i,
    input logic          serializing_hazard_present_i,
    input icache_event_t icache_event_i,
    input dcache_event_t dcache_event_i
);
  logic window_active_q;
  logic recovery_pending_q;
  logic cycle_read_present;
  logic recovery_present;
  logic [31:0] cycle_start_q;
  longint unsigned window_count_q;
  longint unsigned cycle_count_q;
  longint unsigned category_count_array_q [8];
  longint unsigned redirect_count_q;
  longint unsigned recovery_cycle_count_q;
  longint unsigned lsu_busy_cycle_count_q;
  longint unsigned icache_miss_count_q;
  longint unsigned dcache_miss_count_q;
  longint unsigned dirty_miss_count_q;
  int unsigned category_index;

  // csrr rd,mcycle = CSRRS rd,mcycle,x0。不能把其他 CSR 写操作当作标记。
  assign cycle_read_present = commit_valid_i && !commit_i.trap_taken &&
                              commit_i.instruction[31:20] == 12'hb00 &&
                              commit_i.instruction[19:12] == 8'h02 &&
                              commit_i.instruction[6:0] == 7'h73 && commit_i.gpr_write;
  assign recovery_present = recovery_pending_q || redirect_occurred_i;

  always_comb begin
    category_index = 7;
    if (issue_occurred_i) category_index = 0;
    else if (recovery_present) category_index = 1;
    else if (lsu_busy_i) category_index = 2;
    else if (execute_result_blocked_i) category_index = 3;
    else if (execute_valid_i) category_index = 4;
    else if (register_read_valid_i && raw_hazard_present_i) category_index = 5;
    else if (register_read_valid_i && serializing_hazard_present_i) category_index = 6;
  end

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      window_active_q          <= 1'b0;
      recovery_pending_q       <= 1'b0;
      cycle_start_q            <= '0;
      window_count_q           <= 0;
      cycle_count_q            <= 0;
      redirect_count_q         <= 0;
      recovery_cycle_count_q   <= 0;
      lsu_busy_cycle_count_q   <= 0;
      icache_miss_count_q      <= 0;
      dcache_miss_count_q      <= 0;
      dirty_miss_count_q       <= 0;
      foreach (category_count_array_q[index]) category_count_array_q[index] <= 0;
    end else begin
      if (redirect_occurred_i) recovery_pending_q <= 1'b1;
      else if (issue_occurred_i) recovery_pending_q <= 1'b0;
      // [开始提交, 结束提交)：包括开始标记所在拍，不包括结束标记所在拍。
      if ((window_active_q && !cycle_read_present) ||
          (!window_active_q && cycle_read_present)) begin
        cycle_count_q <= cycle_count_q + 1;
        category_count_array_q[category_index] <= category_count_array_q[category_index] + 1;
        if (redirect_occurred_i) redirect_count_q <= redirect_count_q + 1;
        if (recovery_present && !issue_occurred_i)
          recovery_cycle_count_q <= recovery_cycle_count_q + 1;
        if (lsu_busy_i) lsu_busy_cycle_count_q <= lsu_busy_cycle_count_q + 1;
        if (icache_event_i.miss_occurred) icache_miss_count_q <= icache_miss_count_q + 1;
        if (dcache_event_i.miss_occurred) dcache_miss_count_q <= dcache_miss_count_q + 1;
        if (dcache_event_i.dirty_victim_miss_occurred) dirty_miss_count_q <= dirty_miss_count_q + 1;
      end
      if (cycle_read_present) begin
        window_active_q <= !window_active_q;
        if (!window_active_q) begin
          cycle_start_q <= commit_i.gpr_wdata;
          window_count_q <= window_count_q + 1;
        end else begin
          $display("ISSUE_WINDOW end=%0d sampled_cycles=%0d cumulative_observed_cycles=%0d",
                   window_count_q, 32'(commit_i.gpr_wdata - cycle_start_q), cycle_count_q);
        end
      end
    end
  end

  final begin
    $display("ISSUE_WINDOW total windows=%0d active=%0d cycles=%0d issue=%0d recovery=%0d lsu_block=%0d result_block=%0d execute_wait=%0d raw=%0d serial=%0d delivery_gap=%0d redirects=%0d lsu_busy=%0d recovery_observed=%0d ic_miss=%0d dc_miss=%0d dirty_miss=%0d",
             window_count_q, window_active_q, cycle_count_q,
             category_count_array_q[0], category_count_array_q[1], category_count_array_q[2],
             category_count_array_q[3], category_count_array_q[4], category_count_array_q[5],
             category_count_array_q[6], category_count_array_q[7], redirect_count_q,
             lsu_busy_cycle_count_q, recovery_cycle_count_q, icache_miss_count_q,
             dcache_miss_count_q, dirty_miss_count_q);
  end
endmodule
`endif
