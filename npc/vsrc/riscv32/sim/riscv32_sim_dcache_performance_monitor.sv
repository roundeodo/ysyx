`ifdef VERILATOR

module riscv32_sim_dcache_performance_monitor
  import riscv32_pkg::*;
(
    input logic clk_i,
    input logic rst_ni,

    input dcache_event_t dcache_event_i
);
  // 这些寄存器只用于仿真统计，不属于架构状态，也不参与D-cache控制。
  logic [63:0] lookup_count_q;
  logic [63:0] load_lookup_count_q;
  logic [63:0] store_lookup_count_q;
  logic [63:0] hit_count_q;
  logic [63:0] load_hit_count_q;
  logic [63:0] store_hit_count_q;
  logic [63:0] miss_count_q;
  logic [63:0] load_miss_count_q;
  logic [63:0] store_miss_count_q;
  logic [63:0] miss_response_count_q;
  logic [63:0] clean_miss_response_count_q;
  logic [63:0] dirty_miss_response_count_q;
  logic [63:0] dirty_victim_miss_count_q;
  logic [63:0] refill_request_count_q;
  logic [63:0] refill_word_count_q;
  logic [63:0] refill_transaction_count_q;
  logic [63:0] line_install_count_q;
  logic [63:0] writeback_request_count_q;
  logic [63:0] writeback_response_count_q;
  logic [63:0] lookup_request_wait_cycle_count_q;
  logic [63:0] store_hit_and_next_lookup_count_q;
  logic [63:0] hit_latency_cycle_sum_q;
  logic [63:0] miss_response_latency_cycle_sum_q;
  logic [63:0] clean_miss_response_latency_cycle_sum_q;
  logic [63:0] dirty_miss_response_latency_cycle_sum_q;

  // 当前阻塞式D-cache最多只有一个需求lookup在途。未来引入MSHR后，计时器必须
  // 按transaction_id分项保存，不能继续使用这个标量状态。
  logic [63:0] lookup_elapsed_cycle_count_q;
  logic        lookup_timer_active_q;
  logic        active_lookup_is_store_q;
  logic        lookup_classified_as_miss_q;
  logic        active_miss_has_dirty_victim_q;
  logic        lookup_response_counted_q;

  logic lookup_response_available_for_active_request;

  assign lookup_response_available_for_active_request =
      dcache_event_i.lookup_response_present &&
      !lookup_response_counted_q &&
      (lookup_timer_active_q || dcache_event_i.lookup_occurred);

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

  // 请求握手启动计时；响应首次present结束计时。响应若被LSU反压而保持多拍，
  // lookup_response_counted_q保证该事务只被统计一次。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      lookup_count_q                       <= '0;
      load_lookup_count_q                  <= '0;
      store_lookup_count_q                 <= '0;
      hit_count_q                          <= '0;
      load_hit_count_q                     <= '0;
      store_hit_count_q                    <= '0;
      miss_count_q                         <= '0;
      load_miss_count_q                    <= '0;
      store_miss_count_q                   <= '0;
      miss_response_count_q                <= '0;
      clean_miss_response_count_q          <= '0;
      dirty_miss_response_count_q          <= '0;
      dirty_victim_miss_count_q            <= '0;
      refill_request_count_q               <= '0;
      refill_word_count_q                  <= '0;
      refill_transaction_count_q           <= '0;
      line_install_count_q                 <= '0;
      writeback_request_count_q            <= '0;
      writeback_response_count_q           <= '0;
      lookup_request_wait_cycle_count_q    <= '0;
      store_hit_and_next_lookup_count_q    <= '0;
      hit_latency_cycle_sum_q              <= '0;
      miss_response_latency_cycle_sum_q    <= '0;
      clean_miss_response_latency_cycle_sum_q <= '0;
      dirty_miss_response_latency_cycle_sum_q <= '0;
      lookup_elapsed_cycle_count_q         <= '0;
      lookup_timer_active_q                <= 1'b0;
      active_lookup_is_store_q             <= 1'b0;
      lookup_classified_as_miss_q          <= 1'b0;
      active_miss_has_dirty_victim_q       <= 1'b0;
      lookup_response_counted_q            <= 1'b0;
    end else begin
      lookup_request_wait_cycle_count_q <= lookup_request_wait_cycle_count_q +
                                             64'(dcache_event_i.lookup_request_waiting);
      store_hit_and_next_lookup_count_q <= store_hit_and_next_lookup_count_q +
                                             64'(
                                                 dcache_event_i.
                                                 store_hit_and_next_lookup_occurred
                                             );
      dirty_victim_miss_count_q         <= dirty_victim_miss_count_q +
                                             64'(dcache_event_i.dirty_victim_miss_occurred);
      refill_request_count_q            <= refill_request_count_q +
                                             64'(dcache_event_i.refill_request_occurred);
      refill_word_count_q               <= refill_word_count_q +
                                             64'(dcache_event_i.refill_word_occurred);
      refill_transaction_count_q        <= refill_transaction_count_q +
                                             64'(dcache_event_i.refill_transaction_completed_occurred);
      line_install_count_q              <= line_install_count_q +
                                             64'(dcache_event_i.line_install_occurred);
      writeback_request_count_q         <= writeback_request_count_q +
                                             64'(dcache_event_i.writeback_request_occurred);
      writeback_response_count_q        <= writeback_response_count_q +
                                             64'(dcache_event_i.writeback_response_occurred);

      if (lookup_timer_active_q) begin
        lookup_elapsed_cycle_count_q <= lookup_elapsed_cycle_count_q + 64'd1;
      end

      if (dcache_event_i.miss_occurred) begin
        miss_count_q                <= miss_count_q + 64'd1;
        lookup_classified_as_miss_q <= 1'b1;
        if (active_lookup_is_store_q) begin
          store_miss_count_q <= store_miss_count_q + 64'd1;
        end else begin
          load_miss_count_q <= load_miss_count_q + 64'd1;
        end
      end

      if (dcache_event_i.dirty_victim_miss_occurred) begin
        active_miss_has_dirty_victim_q <= 1'b1;
      end

      if (lookup_response_available_for_active_request) begin
        if (dcache_event_i.lookup_response_is_cache_hit) begin
          hit_count_q             <= hit_count_q + 64'd1;
          hit_latency_cycle_sum_q <= hit_latency_cycle_sum_q +
                                     lookup_elapsed_cycle_count_q + 64'd1;
          if (active_lookup_is_store_q) begin
            store_hit_count_q <= store_hit_count_q + 64'd1;
          end else begin
            load_hit_count_q <= load_hit_count_q + 64'd1;
          end
        end else if (lookup_classified_as_miss_q || dcache_event_i.miss_occurred) begin
          miss_response_count_q         <= miss_response_count_q + 64'd1;
          miss_response_latency_cycle_sum_q <= miss_response_latency_cycle_sum_q +
                                                lookup_elapsed_cycle_count_q + 64'd1;
          if (active_miss_has_dirty_victim_q ||
              dcache_event_i.dirty_victim_miss_occurred) begin
            dirty_miss_response_count_q <= dirty_miss_response_count_q + 64'd1;
            dirty_miss_response_latency_cycle_sum_q <=
                dirty_miss_response_latency_cycle_sum_q +
                lookup_elapsed_cycle_count_q + 64'd1;
          end else begin
            clean_miss_response_count_q <= clean_miss_response_count_q + 64'd1;
            clean_miss_response_latency_cycle_sum_q <=
                clean_miss_response_latency_cycle_sum_q +
                lookup_elapsed_cycle_count_q + 64'd1;
          end
        end

        lookup_elapsed_cycle_count_q <= '0;
        lookup_timer_active_q        <= 1'b0;
        lookup_classified_as_miss_q  <= 1'b0;
        active_miss_has_dirty_victim_q <= 1'b0;
        lookup_response_counted_q    <= 1'b1;
      end

      // 连续load hit可在旧响应交付的同拍接收新请求，因此新请求更新放在响应处理之后，
      // 让新的活动事务状态覆盖刚结束的旧事务状态。
      if (dcache_event_i.lookup_occurred) begin
        lookup_count_q                <= lookup_count_q + 64'd1;
        lookup_elapsed_cycle_count_q  <= '0;
        lookup_timer_active_q         <= 1'b1;
        active_lookup_is_store_q      <= dcache_event_i.lookup_is_store;
        lookup_classified_as_miss_q   <= 1'b0;
        active_miss_has_dirty_victim_q <= 1'b0;
        lookup_response_counted_q     <= 1'b0;
        if (dcache_event_i.lookup_is_store) begin
          store_lookup_count_q <= store_lookup_count_q + 64'd1;
        end else begin
          load_lookup_count_q <= load_lookup_count_q + 64'd1;
        end
      end
    end
  end

  final begin
    if (lookup_count_q != 0) begin
      $display("");
      $display("================ D-cache performance counters ============");
      $display("lookups / hits / misses                    : %0d / %0d / %0d",
               lookup_count_q, hit_count_q, miss_count_q);
      $display("D-cache hit rate                           : %.3f%%",
               calculate_percentage(hit_count_q, hit_count_q + miss_count_q));
      $display("load lookups / hits / misses               : %0d / %0d / %0d",
               load_lookup_count_q, load_hit_count_q, load_miss_count_q);
      $display("store lookups / hits / misses              : %0d / %0d / %0d",
               store_lookup_count_q, store_hit_count_q, store_miss_count_q);
      $display("average hit response latency               : %.3f cycles",
               calculate_average_cycles(hit_latency_cycle_sum_q, hit_count_q));
      $display("average miss response latency              : %.3f cycles",
               calculate_average_cycles(miss_response_latency_cycle_sum_q,
                                        miss_response_count_q));
      $display("  clean-victim miss latency                : %.3f cycles (%0d)",
               calculate_average_cycles(clean_miss_response_latency_cycle_sum_q,
                                        clean_miss_response_count_q),
               clean_miss_response_count_q);
      $display("  dirty-victim miss latency                : %.3f cycles (%0d)",
               calculate_average_cycles(dirty_miss_response_latency_cycle_sum_q,
                                        dirty_miss_response_count_q),
               dirty_miss_response_count_q);
      $display("average miss penalty                       : %.3f cycles",
               calculate_miss_penalty());
      $display("D-cache AMAT                               : %.3f cycles",
               calculate_average_cycles(
                   hit_latency_cycle_sum_q + miss_response_latency_cycle_sum_q,
                   hit_count_q + miss_response_count_q));
      $display("dirty victim misses                        : %0d (%.3f%% of misses)",
               dirty_victim_miss_count_q,
               calculate_percentage(dirty_victim_miss_count_q, miss_count_q));
      $display("refill requests / words / completions      : %0d / %0d / %0d",
               refill_request_count_q, refill_word_count_q, refill_transaction_count_q);
      $display("line installs / writeback requests/responses: %0d / %0d / %0d",
               line_install_count_q, writeback_request_count_q, writeback_response_count_q);
      $display("lookup request waiting cycles              : %0d",
               lookup_request_wait_cycle_count_q);
      $display("store-hit same-cycle next lookups          : %0d",
               store_hit_and_next_lookup_count_q);
      $display("==========================================================");
    end
  end

  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      assert ((hit_count_q + miss_count_q) <= lookup_count_q)
      else $error("D-cache classified more requests than it accepted");

      assert ((load_lookup_count_q + store_lookup_count_q) == lookup_count_q)
      else $error("D-cache load/store request classification is inconsistent");

      assert ((load_hit_count_q + store_hit_count_q) == hit_count_q)
      else $error("D-cache load/store hit classification is inconsistent");

      assert ((load_miss_count_q + store_miss_count_q) == miss_count_q)
      else $error("D-cache load/store miss classification is inconsistent");

      assert (dirty_victim_miss_count_q <= miss_count_q)
      else $error("D-cache observed more dirty victims than demand misses");

      assert (miss_response_count_q <= miss_count_q)
      else $error("D-cache returned more miss responses than allocated misses");

      assert ((clean_miss_response_count_q + dirty_miss_response_count_q) ==
              miss_response_count_q)
      else $error("D-cache clean/dirty miss response classification is inconsistent");

      assert (line_install_count_q <= refill_transaction_count_q)
      else $error("D-cache installed more lines than completed refill transactions");

      assert (!(dcache_event_i.lookup_occurred && lookup_timer_active_q &&
                !dcache_event_i.lookup_response_present))
      else $error("D-cache monitor observed more than one outstanding lookup");

      assert (!dcache_event_i.miss_occurred || lookup_timer_active_q ||
              dcache_event_i.lookup_occurred)
      else $error("D-cache monitor observed a miss without an active lookup");
    end
  end

endmodule

`endif
