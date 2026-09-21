// 只观察缓存完成边界；不驱动 CPU 的 valid、ready 或任何状态。
`ifndef SYNTHESIS
`ifdef NPC_ENABLE_SIM_MONITOR
module riscv32_sim_cache_wait_monitor #(
    parameter string CACHE_NAME = "cache"
) (
    input logic clk_i,
    input logic rst_ni,
    input logic completion_i,
    input logic next_lookup_waiting_i,
    input logic same_set_i
);
  longint unsigned completion_count_q;
  longint unsigned waiting_same_set_count_q;
  longint unsigned waiting_other_set_count_q;

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      completion_count_q <= 0;
      waiting_same_set_count_q <= 0;
      waiting_other_set_count_q <= 0;
    end else if (completion_i) begin
      completion_count_q <= completion_count_q + 1;
      if (next_lookup_waiting_i) begin
        if (same_set_i)
          waiting_same_set_count_q <= waiting_same_set_count_q + 1;
        else
          waiting_other_set_count_q <= waiting_other_set_count_q + 1;
      end
    end
  end

  final begin
    $display("CACHE_WAIT %s: completions=%0d next_waiting_same_set=%0d next_waiting_other_set=%0d",
             CACHE_NAME, completion_count_q, waiting_same_set_count_q, waiting_other_set_count_q);
  end
endmodule

// 使用实际次态识别事务释放沿，也覆盖关键字响应反压后的最终释放。
// next_lookup_waiting 排除 S1 占用和维护；剩下的阻塞来自 miss 尚未释放。
bind riscv32_icache riscv32_sim_cache_wait_monitor #(.CACHE_NAME("I-cache"))
    u_cache_wait_monitor (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .completion_i(miss_transaction_present &&
            u_riscv32_icache_miss_unit.state_d == u_riscv32_icache_miss_unit.MISS_IDLE),
        .next_lookup_waiting_i(lookup_req_valid_i && !lookup_req_ready_o &&
            lookup_s1_ready && !invalidate_req_i),
        .same_set_i(get_icache_set_index(lookup_req_i.fetch_addr) ==
            u_riscv32_icache_miss_unit.critical_set_index)
    );

bind riscv32_dcache riscv32_sim_cache_wait_monitor #(.CACHE_NAME("D-cache"))
    u_cache_wait_monitor (
        .clk_i(clk_i),
        .rst_ni(rst_ni),
        .completion_i(miss_transaction_present && !u_miss_unit.clean_operation_q &&
            u_miss_unit.state_d == u_miss_unit.MISS_IDLE),
        .next_lookup_waiting_i(data_memory_req_valid_i && !data_memory_req_ready_o &&
            (!lookup_s1_present_q || local_resp_handshake) && !clean_blocks_lookup),
        .same_set_i(get_set_index(data_memory_req_i.addr) == u_miss_unit.active_set_index_q)
    );
`endif
`endif
