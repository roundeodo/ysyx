`ifdef VERILATOR

module riscv32_sim_icache_performance_monitor
  import riscv32_pkg::*;
(
    input logic clk_i,
    input logic rst_ni,

    input icache_event_t icache_event_i,

    output logic [63:0] cacheable_hit_count_o,
    output logic [63:0] cacheable_miss_response_count_o,
    output logic [63:0] hit_latency_cycle_sum_o,
    output logic [63:0] miss_response_latency_cycle_sum_o
);
  // 这些计数器用于验证命中率、AMAT和refill行为，不属于架构状态，也不参与
  // 任意ready、stall或redirect控制。模块仅进入仿真filelist，综合核心中不存在。
  logic [63:0] lookup_count_q;
  logic [63:0] hit_count_q;
  logic [63:0] miss_count_q;
  logic [63:0] miss_response_count_q;
  logic [63:0] refill_word_count_q;
  logic [63:0] refill_line_count_q;
  logic [63:0] refill_transaction_count_q;
  logic [63:0] uncached_access_count_q;
  logic [63:0] stale_response_count_q;
  logic [63:0] lookup_request_wait_cycle_count_q;
  logic [63:0] hit_latency_cycle_sum_q;
  logic [63:0] miss_response_latency_cycle_sum_q;
  logic [63:0] refill_latency_cycle_sum_q;

  // 当前单在途IFU最多只有一个lookup和一个refill在途，因此各用一个计时器。
  // 将来支持多请求在途时，应按frontend tag或MSHR保存各事务起始时间。
  logic [63:0] lookup_elapsed_cycle_count_q;
  logic [63:0] refill_elapsed_cycle_count_q;
  logic        lookup_timer_active_q;
  logic        lookup_classified_as_miss_q;
  logic        lookup_response_counted_q;
  logic        refill_timer_active_q;

  logic lookup_response_available_for_active_request;

  assign lookup_response_available_for_active_request =
      icache_event_i.lookup_response_present &&
      !lookup_response_counted_q &&
      (lookup_timer_active_q || icache_event_i.lookup_occurred);

  // 向综合性能监视器导出原始整数计数。理想流水线估算在统一位置组合退休数、
  // LSU额外等待和I-cache缺失代价，避免从格式化后的平均值反推而产生舍入误差。
  assign cacheable_hit_count_o              = hit_count_q;
  assign cacheable_miss_response_count_o    = miss_response_count_q;
  assign hit_latency_cycle_sum_o            = hit_latency_cycle_sum_q;
  assign miss_response_latency_cycle_sum_o  = miss_response_latency_cycle_sum_q;

  function automatic real calculate_average_cycles(
      input logic [63:0] cycle_sum,
      input logic [63:0] event_count
  );
    if (event_count == 0) begin
      return 0.0;
    end
    return real'(cycle_sum) / real'(event_count);
  endfunction

  function automatic real calculate_percentage(
      input logic [63:0] event_count,
      input logic [63:0] total_count
  );
    if (total_count == 0) begin
      return 0.0;
    end
    return 100.0 * real'(event_count) / real'(total_count);
  endfunction

  function automatic real calculate_miss_penalty();
    if ((hit_count_q == 0) || (miss_response_count_q == 0)) begin
      return 0.0;
    end
    return calculate_average_cycles(
        miss_response_latency_cycle_sum_q, miss_response_count_q
    ) - calculate_average_cycles(hit_latency_cycle_sum_q, hit_count_q);
  endfunction

  // lookup response首次present即结束AMAT计时，不等待下游ready，因此不会把IDU
  // 反压算进cache访问时间。完整line refill的占用时间由另一计时器独立统计。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      lookup_count_q                         <= '0;
      hit_count_q                            <= '0;
      miss_count_q                           <= '0;
      miss_response_count_q                  <= '0;
      refill_word_count_q                    <= '0;
      refill_line_count_q                    <= '0;
      refill_transaction_count_q             <= '0;
      uncached_access_count_q                <= '0;
      stale_response_count_q                 <= '0;
      lookup_request_wait_cycle_count_q      <= '0;
      hit_latency_cycle_sum_q                <= '0;
      miss_response_latency_cycle_sum_q      <= '0;
      refill_latency_cycle_sum_q             <= '0;
      lookup_elapsed_cycle_count_q           <= '0;
      refill_elapsed_cycle_count_q           <= '0;
      lookup_timer_active_q                  <= 1'b0;
      lookup_classified_as_miss_q            <= 1'b0;
      lookup_response_counted_q              <= 1'b0;
      refill_timer_active_q                  <= 1'b0;
    end else begin
      lookup_count_q                    <= lookup_count_q + 64'(icache_event_i.lookup_occurred);
      miss_count_q                      <= miss_count_q + 64'(icache_event_i.miss_occurred);
      refill_word_count_q               <= refill_word_count_q +
                                             64'(icache_event_i.refill_word_occurred);
      refill_line_count_q               <= refill_line_count_q +
                                             64'(icache_event_i.refill_line_completed_occurred);
      uncached_access_count_q           <= uncached_access_count_q +
                                             64'(icache_event_i.uncached_access_occurred);
      stale_response_count_q            <= stale_response_count_q +
                                             64'(icache_event_i.stale_response_discarded_occurred);
      lookup_request_wait_cycle_count_q <= lookup_request_wait_cycle_count_q +
                                             64'(icache_event_i.lookup_request_waiting);

      if (lookup_timer_active_q) begin
        lookup_elapsed_cycle_count_q <= lookup_elapsed_cycle_count_q + 64'd1;
      end
      if (refill_timer_active_q) begin
        refill_elapsed_cycle_count_q <= refill_elapsed_cycle_count_q + 64'd1;
      end

      if (icache_event_i.miss_occurred) begin
        lookup_classified_as_miss_q  <= 1'b1;
        refill_timer_active_q        <= 1'b1;
        refill_elapsed_cycle_count_q <= '0;
      end

      if (lookup_response_available_for_active_request) begin
        if (icache_event_i.lookup_response_is_cache_hit) begin
          hit_count_q             <= hit_count_q + 64'd1;
          hit_latency_cycle_sum_q <= hit_latency_cycle_sum_q +
                                     lookup_elapsed_cycle_count_q + 64'd1;
        end else if (lookup_classified_as_miss_q || icache_event_i.miss_occurred) begin
          miss_response_count_q             <= miss_response_count_q + 64'd1;
          miss_response_latency_cycle_sum_q <= miss_response_latency_cycle_sum_q +
                                                lookup_elapsed_cycle_count_q + 64'd1;
        end

        lookup_elapsed_cycle_count_q      <= '0;
        lookup_timer_active_q             <= 1'b0;
        lookup_classified_as_miss_q       <= 1'b0;
        lookup_response_counted_q         <= 1'b1;
      end

      // response present在下游反压期间会保持多拍，不能把每一拍都视为新响应。
      // 旧响应首次present后设置response_counted；其最终握手与下一请求接收同拍时，
      // lookup_occurred启动新计时器并清除此标志。这样连续命中即使valid不降也能逐事务计数。
      // 只有在“本拍新请求本拍产生响应”这种零延迟接口情况下，才不留下活动计时器。
      if (icache_event_i.lookup_occurred &&
          (!lookup_response_available_for_active_request || lookup_timer_active_q)) begin
        lookup_elapsed_cycle_count_q      <= '0;
        lookup_timer_active_q             <= 1'b1;
        lookup_classified_as_miss_q       <= 1'b0;
        lookup_response_counted_q         <= 1'b0;
      end

      if (icache_event_i.refill_transaction_completed_occurred) begin
        refill_transaction_count_q   <= refill_transaction_count_q + 64'd1;
        refill_latency_cycle_sum_q   <= refill_latency_cycle_sum_q +
                                        refill_elapsed_cycle_count_q + 64'd1;
        refill_elapsed_cycle_count_q <= '0;
        refill_timer_active_q        <= 1'b0;
      end
    end
  end

  final begin
    if ((hit_count_q + miss_response_count_q) != 0) begin
      $display("");
      $display("================ I-cache AMAT counters ===================");
      $display("lookups / cacheable hits / cacheable misses : %0d / %0d / %0d",
               lookup_count_q, hit_count_q, miss_count_q);
      $display("I-cache hit rate                            : %.3f%%",
               calculate_percentage(hit_count_q, hit_count_q + miss_count_q));
      $display("average hit response latency                : %.3f cycles",
               calculate_average_cycles(hit_latency_cycle_sum_q, hit_count_q));
      $display("average miss critical response latency      : %.3f cycles",
               calculate_average_cycles(miss_response_latency_cycle_sum_q,
                                        miss_response_count_q));
      $display("average miss penalty                        : %.3f cycles",
               calculate_miss_penalty());
      $display("I-cache AMAT                                : %.3f cycles",
               calculate_average_cycles(
                   hit_latency_cycle_sum_q + miss_response_latency_cycle_sum_q,
                   hit_count_q + miss_response_count_q));
      $display("average complete refill latency             : %.3f cycles",
               calculate_average_cycles(refill_latency_cycle_sum_q,
                                        refill_transaction_count_q));
      $display("lookup request waiting cycles               : %0d",
               lookup_request_wait_cycle_count_q);
      $display("successful line installs / refill finishes  : %0d / %0d",
               refill_line_count_q, refill_transaction_count_q);
      $display("discarded stale responses                   : %0d",
               stale_response_count_q);
      $display("==========================================================");
    end
  end

  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      assert ((hit_count_q + miss_count_q + uncached_access_count_q) <= lookup_count_q)
      else $error("I-cache classified more requests than it accepted");

      assert (!icache_event_i.lookup_response_is_cache_hit ||
              icache_event_i.lookup_response_present)
      else $error("I-cache marked a response as a hit while no response was present");

      assert (refill_line_count_q <= miss_count_q)
      else $error("I-cache completed more refill lines than cacheable misses");

      assert (miss_response_count_q <= miss_count_q)
      else $error("I-cache returned more miss responses than allocated misses");

      assert (refill_transaction_count_q <= miss_count_q)
      else $error("I-cache finished more refill transactions than allocated misses");

      assert (refill_line_count_q <= refill_transaction_count_q)
      else $error("I-cache installed more lines than completed refill transactions");

      assert (refill_word_count_q >= (refill_line_count_q * ICACHE_WORDS_PER_LINE))
      else $error("I-cache completed a refill line without receiving all words");

      assert (!(icache_event_i.lookup_occurred && lookup_timer_active_q &&
                !icache_event_i.lookup_response_present))
      else $error("I-cache AMAT timer observed more than one outstanding lookup");

      assert (!icache_event_i.miss_occurred || lookup_timer_active_q ||
              icache_event_i.lookup_occurred)
      else $error("I-cache AMAT timer observed a miss without an active lookup");

      assert (!icache_event_i.refill_transaction_completed_occurred ||
              refill_timer_active_q)
      else $error("I-cache refill timer observed completion without an active refill");
    end
  end

endmodule

`endif
