// 仿真报告共用的比例与延迟计算；不进入可综合filelist。
package riscv_sim_statistics_pkg;
  function automatic real calculate_ratio(input logic [63:0] numerator,
                                          input logic [63:0] denominator);
    if (denominator == 0) return 0.0;
    return real'(numerator) / real'(denominator);
  endfunction

  function automatic real calculate_percentage(input logic [63:0] event_count,
                                               input logic [63:0] total_count);
    return 100.0 * calculate_ratio(event_count, total_count);
  endfunction

  function automatic real calculate_miss_penalty(
      input logic [63:0] hit_count, input logic [63:0] miss_response_count,
      input logic [63:0] hit_latency_cycle_sum, input logic [63:0] miss_response_latency_cycle_sum);
    if (hit_count == 0 || miss_response_count == 0) return 0.0;
    return calculate_ratio(
        miss_response_latency_cycle_sum, miss_response_count
    ) - calculate_ratio(
        hit_latency_cycle_sum, hit_count
    );
  endfunction
endpackage
