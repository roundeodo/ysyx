`ifdef VERILATOR

module riscv32_sim_performance_monitor
  import riscv32_pkg::*;
(
    input logic clk_i,
    input logic rst_ni,

    input logic ifu_instruction_request_occurred_i,
    input logic ifu_instruction_request_waiting_i,
    input logic ifu_instruction_response_occurred_i,
    input logic ifu_instruction_response_discarded_occurred_i,
    input logic ifu_instruction_delivery_occurred_i,
    input logic ifu_downstream_waiting_i,
    input logic icache_miss_occurred_i,

    input logic     instruction_decode_occurred_i,
    input fu_type_e decoded_fu_type_i,
    input mem_cmd_e decoded_memory_cmd_i,
    input logic     exu_completion_occurred_i,
    input logic     lsu_completion_occurred_i,
    input logic     instruction_retirement_occurred_i,

    input logic pipeline_raw_hazard_waiting_i,
    input logic pipeline_serializing_waiting_i,
    input logic pipeline_structural_waiting_i,
    input logic frontend_supply_waiting_i,
    input logic pipeline_control_flush_occurred_i,
    input logic pipeline_execute_instruction_discarded_i,
    input logic fetch_taken_prediction_occurred_i,
    input logic execute_misprediction_redirect_occurred_i,

    // 控制流结果在EX级真正完成握手时采样。预测收益必须按实际执行过的控制流指令
    // 统计，不能拿decode数量或redirect数量替代：不跳分支不会产生当前实现的redirect，
    // 而JAL/JALR与条件分支的可预测性也不同。
    input logic             control_flow_resolution_occurred_i,
    input control_flow_op_e resolved_control_flow_op_i,
    input program_counter_t resolved_control_flow_pc_i,
    input logic             resolved_control_flow_taken_i,
    input xlen_data_t       resolved_control_flow_immediate_i,

    input logic     lsu_request_occurred_i,
    input mem_cmd_e lsu_request_memory_cmd_i,
    input logic     lsu_read_address_occurred_i,
    input logic     lsu_read_response_occurred_i,
    input logic     lsu_write_address_occurred_i,
    input logic     lsu_write_data_occurred_i,
    input logic     lsu_write_response_occurred_i,

    input logic [63:0] icache_cacheable_hit_count_i,
    input logic [63:0] icache_cacheable_miss_response_count_i,
    input logic [63:0] icache_hit_latency_cycle_sum_i,
    input logic [63:0] icache_miss_response_latency_cycle_sum_i
);
  logic     [63:0] active_cycle_count_q;
  logic     [63:0] decoded_instruction_count_q;
  logic     [63:0] retired_instruction_count_q;
  logic     [63:0] exu_completion_count_q;
  logic     [63:0] lsu_completion_count_q;
  logic     [63:0] control_recovery_stall_cycle_count_q;
  logic     [63:0] lsu_structural_stall_cycle_count_q;
  logic     [63:0] raw_dependency_stall_cycle_count_q;
  logic     [63:0] serializing_stall_cycle_count_q;
  logic     [63:0] frontend_supply_stall_cycle_count_q;
  logic     [63:0] frontend_request_backpressure_stall_cycle_count_q;
  logic     [63:0] frontend_cache_miss_service_stall_cycle_count_q;
  logic     [63:0] frontend_lookup_response_stall_cycle_count_q;
  logic     [63:0] frontend_request_launch_or_delivery_gap_cycle_count_q;
  logic     [63:0] other_no_issue_cycle_count_q;
  logic     [63:0] pipeline_control_flush_count_q;
  logic     [63:0] pipeline_execute_discard_count_q;
  logic     [63:0] fetch_taken_prediction_count_q;
  logic     [63:0] execute_misprediction_redirect_count_q;
  logic     [63:0] conditional_branch_correction_count_q;
  logic     [63:0] direct_jump_correction_count_q;
  logic     [63:0] indirect_jump_correction_count_q;
  logic            control_recovery_pending_q;

  logic     [63:0] conditional_branch_count_q;
  logic     [63:0] conditional_branch_taken_count_q;
  logic     [63:0] backward_branch_count_q;
  logic     [63:0] backward_branch_taken_count_q;
  logic     [63:0] forward_branch_count_q;
  logic     [63:0] forward_branch_taken_count_q;
  logic     [63:0] direct_jump_count_q;
  logic     [63:0] indirect_jump_count_q;
  logic     [63:0] always_not_taken_prediction_error_count_q;
  logic     [63:0] btfnt_prediction_error_count_q;
  // 仿真专用设计空间模型，不进入可综合core。两种BHT都使用两位饱和计数器，
  // 以真实分支PC索引，从而把容量冲突和热身开销计入候选方案评估。
  logic [1:0] bht_16_counter_array_q[16];
  logic [1:0] bht_64_counter_array_q[64];
  logic [63:0] bht_16_prediction_error_count_q;
  logic [63:0] bht_64_prediction_error_count_q;

  logic     [63:0] integer_instruction_count_q;
  logic     [63:0] branch_instruction_count_q;
  logic     [63:0] memory_instruction_count_q;
  logic     [63:0] load_instruction_count_q;
  logic     [63:0] store_instruction_count_q;
  logic     [63:0] csr_instruction_count_q;
  logic     [63:0] system_instruction_count_q;
  logic     [63:0] unclassified_instruction_count_q;

  logic     [63:0] integer_execution_cycle_sum_q;
  logic     [63:0] branch_execution_cycle_sum_q;
  logic     [63:0] memory_execution_cycle_sum_q;
  logic     [63:0] csr_execution_cycle_sum_q;
  logic     [63:0] system_execution_cycle_sum_q;
  logic     [63:0] unclassified_execution_cycle_sum_q;

  logic            instruction_execution_active_q;
  fu_type_e        active_instruction_fu_type_q;
  logic     [63:0] active_instruction_elapsed_cycle_count_q;

  logic     [63:0] ifu_instruction_request_count_q;
  logic     [63:0] ifu_instruction_response_count_q;
  logic     [63:0] ifu_instruction_delivery_count_q;
  logic     [63:0] ifu_discarded_response_count_q;
  logic     [63:0] ifu_request_wait_cycle_count_q;
  logic     [63:0] ifu_response_wait_cycle_count_q;
  logic     [63:0] ifu_downstream_wait_cycle_count_q;
  logic     [63:0] ifu_response_latency_cycle_sum_q;
  logic     [63:0] ifu_response_elapsed_cycle_count_q;
  logic            ifu_response_pending_q;
  logic            icache_miss_service_pending_q;

  logic     [63:0] lsu_request_count_q;
  logic     [63:0] lsu_load_operation_count_q;
  logic     [63:0] lsu_store_operation_count_q;
  logic     [63:0] lsu_load_operation_latency_cycle_sum_q;
  logic     [63:0] lsu_store_operation_latency_cycle_sum_q;
  logic     [63:0] lsu_operation_elapsed_cycle_count_q;
  mem_cmd_e        active_lsu_memory_cmd_q;
  logic            lsu_operation_active_q;

  logic     [63:0] lsu_read_bus_transaction_count_q;
  logic     [63:0] lsu_read_bus_latency_cycle_sum_q;
  logic     [63:0] lsu_read_bus_elapsed_cycle_count_q;
  logic            lsu_read_response_pending_q;

  logic     [63:0] lsu_write_bus_transaction_count_q;
  logic     [63:0] lsu_write_bus_latency_cycle_sum_q;
  logic     [63:0] lsu_write_bus_elapsed_cycle_count_q;
  logic            lsu_write_response_pending_q;
  logic            lsu_write_address_handshake_occurred_q;
  logic            lsu_write_data_handshake_occurred_q;

  logic            instruction_completion_occurred;
  logic            lsu_write_request_channels_handshake_occurred;

  assign instruction_completion_occurred = exu_completion_occurred_i || lsu_completion_occurred_i;

  assign lsu_write_request_channels_handshake_occurred =
      (lsu_write_address_handshake_occurred_q || lsu_write_address_occurred_i) &&
      (lsu_write_data_handshake_occurred_q || lsu_write_data_occurred_i);

  function automatic real calculate_ratio(input logic [63:0] numerator,
                                          input logic [63:0] denominator);
    if (denominator == 0) begin
      return 0.0;
    end
    return real'(numerator) / real'(denominator);
  endfunction

  function automatic real calculate_percentage(input logic [63:0] event_count,
                                               input logic [63:0] total_count);
    if (total_count == 0) begin
      return 0.0;
    end
    return (100.0 * real'(event_count)) / real'(total_count);
  endfunction

  function automatic real calculate_average_cycles(input logic [63:0] cycle_sum,
                                                   input logic [63:0] event_count);
    if (event_count == 0) begin
      return 0.0;
    end
    return real'(cycle_sum) / real'(event_count);
  endfunction

  function automatic logic [1:0] update_bht_counter(input logic [1:0] counter,
                                                    input logic       branch_taken);
    if (branch_taken) begin
      return (counter == 2'b11) ? counter : counter + 2'b01;
    end
    return (counter == 2'b00) ? counter : counter - 2'b01;
  endfunction

  function automatic real calculate_memory_execution_excess_cycles();
    if (memory_execution_cycle_sum_q <= memory_instruction_count_q) begin
      return 0.0;
    end
    return real'(memory_execution_cycle_sum_q - memory_instruction_count_q);
  endfunction

  function automatic real calculate_icache_miss_penalty_cycle_sum();
    real average_hit_latency;
    real miss_response_cycle_sum;

    if ((icache_cacheable_hit_count_i == 0) || (icache_cacheable_miss_response_count_i == 0)) begin
      return 0.0;
    end
    average_hit_latency     = real'(icache_hit_latency_cycle_sum_i) /
                              real'(icache_cacheable_hit_count_i);
    miss_response_cycle_sum = real'(icache_miss_response_latency_cycle_sum_i);
    return miss_response_cycle_sum -
           real'(icache_cacheable_miss_response_count_i) * average_hit_latency;
  endfunction

  function automatic real calculate_oracle_single_cycle_data_memory_cycle_count();
    // 这不是某个可实现D-cache的性能模型。它把每条load/store的执行时间强制缩短到一拍，
    // 只用于给数据供给优化建立绝对上限，不包含miss、写回、端口冲突和uncached访问。
    return real'(active_cycle_count_q) - calculate_memory_execution_excess_cycles();
  endfunction

  function automatic real calculate_ideal_single_issue_pipeline_cycle_count();
    // 一拍基线覆盖每条退休指令；访存指令仍保留超过一拍的真实LSU等待；
    // I-cache只保留miss相对正常hit多出的供给停顿。
    return real'(retired_instruction_count_q) +
           calculate_memory_execution_excess_cycles() +
           calculate_icache_miss_penalty_cycle_sum();
  endfunction

  function automatic real calculate_ideal_pipeline_and_oracle_data_memory_cycle_count();
    return real'(retired_instruction_count_q) + calculate_icache_miss_penalty_cycle_sum();
  endfunction

  function automatic real calculate_speedup(input real projected_cycle_count);
    if (projected_cycle_count <= 0.0) begin
      return 0.0;
    end
    return real'(active_cycle_count_q) / projected_cycle_count;
  endfunction

  task automatic add_instruction_execution_cycles(input fu_type_e instruction_fu_type,
                                                  input logic [63:0] execution_cycle_count);
    unique case (instruction_fu_type)
      FU_INT: begin
        integer_execution_cycle_sum_q <= integer_execution_cycle_sum_q + execution_cycle_count;
      end
      FU_BRANCH: begin
        branch_execution_cycle_sum_q <= branch_execution_cycle_sum_q + execution_cycle_count;
      end
      FU_LSU: begin
        memory_execution_cycle_sum_q <= memory_execution_cycle_sum_q + execution_cycle_count;
      end
      FU_CSR: begin
        csr_execution_cycle_sum_q <= csr_execution_cycle_sum_q + execution_cycle_count;
      end
      FU_SYSTEM: begin
        system_execution_cycle_sum_q <= system_execution_cycle_sum_q + execution_cycle_count;
      end
      default: begin
        unclassified_execution_cycle_sum_q <= unclassified_execution_cycle_sum_q +
                                              execution_cycle_count;
      end
    endcase
  endtask

  // Count completed transfers and decoded instruction classes. VALID without
  // READY is never counted as another instruction or bus transaction.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      active_cycle_count_q                                <= '0;
      decoded_instruction_count_q                         <= '0;
      retired_instruction_count_q                         <= '0;
      exu_completion_count_q                              <= '0;
      lsu_completion_count_q                              <= '0;
      control_recovery_stall_cycle_count_q               <= '0;
      lsu_structural_stall_cycle_count_q                  <= '0;
      raw_dependency_stall_cycle_count_q                  <= '0;
      serializing_stall_cycle_count_q                     <= '0;
      frontend_supply_stall_cycle_count_q                 <= '0;
      frontend_request_backpressure_stall_cycle_count_q   <= '0;
      frontend_cache_miss_service_stall_cycle_count_q     <= '0;
      frontend_lookup_response_stall_cycle_count_q        <= '0;
      frontend_request_launch_or_delivery_gap_cycle_count_q <= '0;
      other_no_issue_cycle_count_q                        <= '0;
      pipeline_control_flush_count_q                      <= '0;
      pipeline_execute_discard_count_q                    <= '0;
      fetch_taken_prediction_count_q                      <= '0;
      execute_misprediction_redirect_count_q              <= '0;
      conditional_branch_correction_count_q               <= '0;
      direct_jump_correction_count_q                      <= '0;
      indirect_jump_correction_count_q                    <= '0;
      conditional_branch_count_q              <= '0;
      conditional_branch_taken_count_q        <= '0;
      backward_branch_count_q                 <= '0;
      backward_branch_taken_count_q           <= '0;
      forward_branch_count_q                  <= '0;
      forward_branch_taken_count_q            <= '0;
      direct_jump_count_q                     <= '0;
      indirect_jump_count_q                   <= '0;
      always_not_taken_prediction_error_count_q <= '0;
      btfnt_prediction_error_count_q          <= '0;
      integer_instruction_count_q             <= '0;
      branch_instruction_count_q              <= '0;
      memory_instruction_count_q              <= '0;
      load_instruction_count_q                <= '0;
      store_instruction_count_q               <= '0;
      csr_instruction_count_q                 <= '0;
      system_instruction_count_q              <= '0;
      unclassified_instruction_count_q        <= '0;
    end else begin
      active_cycle_count_q <= active_cycle_count_q + 64'd1;

      if (instruction_decode_occurred_i) begin
        decoded_instruction_count_q <= decoded_instruction_count_q + 64'd1;
        unique case (decoded_fu_type_i)
          FU_INT:    integer_instruction_count_q <= integer_instruction_count_q + 64'd1;
          FU_BRANCH: branch_instruction_count_q <= branch_instruction_count_q + 64'd1;
          FU_LSU: begin
            memory_instruction_count_q <= memory_instruction_count_q + 64'd1;
            if (decoded_memory_cmd_i == MEM_CMD_LOAD) begin
              load_instruction_count_q <= load_instruction_count_q + 64'd1;
            end else if (decoded_memory_cmd_i == MEM_CMD_STORE) begin
              store_instruction_count_q <= store_instruction_count_q + 64'd1;
            end
          end
          FU_CSR:    csr_instruction_count_q <= csr_instruction_count_q + 64'd1;
          FU_SYSTEM: system_instruction_count_q <= system_instruction_count_q + 64'd1;
          default: begin
            unclassified_instruction_count_q <= unclassified_instruction_count_q + 64'd1;
          end
        endcase
      end
      if (instruction_retirement_occurred_i) begin
        retired_instruction_count_q <= retired_instruction_count_q + 64'd1;
      end
      if (exu_completion_occurred_i) begin
        exu_completion_count_q <= exu_completion_count_q + 64'd1;
      end
      if (lsu_completion_occurred_i) begin
        lsu_completion_count_q <= lsu_completion_count_q + 64'd1;
      end
      // 每个未发射周期只归属一个首要原因。以“译码指令进入ID/EX”作为
      // 单发射流水线的有效槽位，避免将LSU busy期间同时出现的RAW、前端反压
      // 和响应在途重复计数。优先级表示恢复原因和最老的阻塞来源。
      if (!instruction_decode_occurred_i) begin
        if (pipeline_control_flush_occurred_i || control_recovery_pending_q) begin
          control_recovery_stall_cycle_count_q <= control_recovery_stall_cycle_count_q + 64'd1;
        end else if (pipeline_structural_waiting_i) begin
          lsu_structural_stall_cycle_count_q <= lsu_structural_stall_cycle_count_q + 64'd1;
        end else if (pipeline_raw_hazard_waiting_i) begin
          raw_dependency_stall_cycle_count_q <= raw_dependency_stall_cycle_count_q + 64'd1;
        end else if (pipeline_serializing_waiting_i) begin
          serializing_stall_cycle_count_q <= serializing_stall_cycle_count_q + 64'd1;
        end else if (frontend_supply_waiting_i) begin
          frontend_supply_stall_cycle_count_q <= frontend_supply_stall_cycle_count_q + 64'd1;
          // Frontend子分类仍保持互斥。优先记录当前真正阻止请求前进的反压；
          // miss一旦被I-cache确认，直到对应响应返回都归入miss服务；其余在途
          // lookup属于正常tag/data流水等待。没有事务在途时才归入请求启动或交付间隙。
          if (ifu_instruction_request_waiting_i) begin
            frontend_request_backpressure_stall_cycle_count_q <=
                frontend_request_backpressure_stall_cycle_count_q + 64'd1;
          end else if (icache_miss_service_pending_q || icache_miss_occurred_i) begin
            frontend_cache_miss_service_stall_cycle_count_q <=
                frontend_cache_miss_service_stall_cycle_count_q + 64'd1;
          end else if (ifu_response_pending_q || ifu_instruction_request_occurred_i) begin
            frontend_lookup_response_stall_cycle_count_q <=
                frontend_lookup_response_stall_cycle_count_q + 64'd1;
          end else begin
            frontend_request_launch_or_delivery_gap_cycle_count_q <=
                frontend_request_launch_or_delivery_gap_cycle_count_q + 64'd1;
          end
        end else begin
          other_no_issue_cycle_count_q <= other_no_issue_cycle_count_q + 64'd1;
        end
      end
      if (pipeline_control_flush_occurred_i) begin
        pipeline_control_flush_count_q <= pipeline_control_flush_count_q + 64'd1;
      end
      if (pipeline_execute_instruction_discarded_i) begin
        pipeline_execute_discard_count_q <= pipeline_execute_discard_count_q + 64'd1;
      end
      if (fetch_taken_prediction_occurred_i) begin
        fetch_taken_prediction_count_q <= fetch_taken_prediction_count_q + 64'd1;
      end
      if (execute_misprediction_redirect_occurred_i) begin
        execute_misprediction_redirect_count_q <=
            execute_misprediction_redirect_count_q + 64'd1;
        // 纠错事件和控制流完成来自同一个EX握手，因此可直接按实际op分类。
        // 这组计数反映RTL预测器真实表现，不受离线trace链接地址差异影响。
        unique case (resolved_control_flow_op_i)
          CF_BRANCH: conditional_branch_correction_count_q <=
              conditional_branch_correction_count_q + 64'd1;
          CF_JAL: direct_jump_correction_count_q <= direct_jump_correction_count_q + 64'd1;
          CF_JALR: indirect_jump_correction_count_q <= indirect_jump_correction_count_q + 64'd1;
          default: ;
        endcase
      end

      if (control_flow_resolution_occurred_i) begin
        unique case (resolved_control_flow_op_i)
          CF_BRANCH: begin
            conditional_branch_count_q <= conditional_branch_count_q + 64'd1;
            if (resolved_control_flow_taken_i) begin
              conditional_branch_taken_count_q <= conditional_branch_taken_count_q + 64'd1;
              // 当前RTL按顺序PC取指，所以条件分支实际跳转就是一次预测错误。
              always_not_taken_prediction_error_count_q <=
                  always_not_taken_prediction_error_count_q + 64'd1;
            end

            // BTFNT只使用分支立即数符号：负偏移预测跳转，正偏移预测不跳。
            // 这里直接统计候选策略的错误数，尚未改变RTL行为。
            if (resolved_control_flow_immediate_i[XLEN-1]) begin
              backward_branch_count_q <= backward_branch_count_q + 64'd1;
              if (resolved_control_flow_taken_i) begin
                backward_branch_taken_count_q <= backward_branch_taken_count_q + 64'd1;
              end else begin
                btfnt_prediction_error_count_q <= btfnt_prediction_error_count_q + 64'd1;
              end
            end else begin
              forward_branch_count_q <= forward_branch_count_q + 64'd1;
              if (resolved_control_flow_taken_i) begin
                forward_branch_taken_count_q <= forward_branch_taken_count_q + 64'd1;
                btfnt_prediction_error_count_q <= btfnt_prediction_error_count_q + 64'd1;
              end
            end
          end

          CF_JAL: begin
            direct_jump_count_q <= direct_jump_count_q + 64'd1;
            // JAL恒跳转且目标为PC+imm；始终顺序取指一定预测错误，BTFNT扩展策略则
            // 可在译码时准确得到方向和目标，因此不计入BTFNT错误。
            always_not_taken_prediction_error_count_q <=
                always_not_taken_prediction_error_count_q + 64'd1;
          end

          CF_JALR: begin
            indirect_jump_count_q <= indirect_jump_count_q + 64'd1;
            // 没有BTB/RAS时，JALR目标无法仅由指令位得到；两种低成本静态策略均按
            // 顺序PC预测，所以每条正常完成的JALR都是一次预测错误。
            always_not_taken_prediction_error_count_q <=
                always_not_taken_prediction_error_count_q + 64'd1;
            btfnt_prediction_error_count_q <= btfnt_prediction_error_count_q + 64'd1;
          end

          default: ;
        endcase
      end
    end
  end

  // 两种候选BHT从弱不跳转状态启动。这里只模拟条件分支方向；JAL仍可由静态预译码
  // 准确处理，JALR在没有BTB/RAS时仍算一次错误，最终报告会单独把它加回。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      bht_16_prediction_error_count_q <= '0;
      bht_64_prediction_error_count_q <= '0;
      for (int unsigned entry = 0; entry < 16; entry++) begin
        bht_16_counter_array_q[entry] <= 2'b01;
      end
      for (int unsigned entry = 0; entry < 64; entry++) begin
        bht_64_counter_array_q[entry] <= 2'b01;
      end
    end else if (control_flow_resolution_occurred_i &&
                 (resolved_control_flow_op_i == CF_BRANCH)) begin
      if (bht_16_counter_array_q[resolved_control_flow_pc_i[5:2]][1] !=
          resolved_control_flow_taken_i) begin
        bht_16_prediction_error_count_q <= bht_16_prediction_error_count_q + 64'd1;
      end
      if (bht_64_counter_array_q[resolved_control_flow_pc_i[7:2]][1] !=
          resolved_control_flow_taken_i) begin
        bht_64_prediction_error_count_q <= bht_64_prediction_error_count_q + 64'd1;
      end

      bht_16_counter_array_q[resolved_control_flow_pc_i[5:2]] <= update_bht_counter(
          bht_16_counter_array_q[resolved_control_flow_pc_i[5:2]],
          resolved_control_flow_taken_i
      );
      bht_64_counter_array_q[resolved_control_flow_pc_i[7:2]] <= update_bht_counter(
          bht_64_counter_array_q[resolved_control_flow_pc_i[7:2]],
          resolved_control_flow_taken_i
      );
    end
  end

  // I-cache在lookup流水线末端才知道hit/miss。miss事件置位后，该标志保持到
  // 对应lookup响应真正与IFU握手，用于把普通lookup延迟和下层存储服务延迟分开。
  // 响应优先于同拍miss，避免已经完成的事务在下一拍仍被误认为正在服务。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      icache_miss_service_pending_q <= 1'b0;
    end else if (ifu_instruction_response_occurred_i) begin
      icache_miss_service_pending_q <= 1'b0;
    end else if (icache_miss_occurred_i) begin
      icache_miss_service_pending_q <= 1'b1;
    end
  end

  // EX纠错或提交级redirect到恢复目标真正进入ID/EX之间的周期属于控制恢复代价。
  // fetch预测不会清空队列，其中尚未发射的老指令仍是有效工作；预测目标尚未到达造成的
  // 空泡会自然归入frontend supply，不能与错误路径恢复混为一类。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      control_recovery_pending_q <= 1'b0;
    end else begin
      if (instruction_decode_occurred_i) begin
        control_recovery_pending_q <= 1'b0;
      end
      if (pipeline_control_flush_occurred_i) begin
        control_recovery_pending_q <= 1'b1;
      end
    end
  end

  // 当前顺序流水线的ID/EX中最多有一条执行中指令，但“旧指令完成”和“新指令进入ID/EX”
  // 可以同拍发生。完成事件因此先结算旧上下文，再由decode事件建立新上下文；不能把同拍
  // 的两个事件视为同一条组合完成指令。未来乱序核需要改成按ROB tag索引的时间戳表。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      instruction_execution_active_q           <= 1'b0;
      active_instruction_fu_type_q             <= FU_NONE;
      active_instruction_elapsed_cycle_count_q <= '0;
      integer_execution_cycle_sum_q            <= '0;
      branch_execution_cycle_sum_q             <= '0;
      memory_execution_cycle_sum_q             <= '0;
      csr_execution_cycle_sum_q                <= '0;
      system_execution_cycle_sum_q             <= '0;
      unclassified_execution_cycle_sum_q       <= '0;
    end else begin
      if (instruction_execution_active_q && instruction_completion_occurred) begin
        add_instruction_execution_cycles(active_instruction_fu_type_q,
                                         active_instruction_elapsed_cycle_count_q + 64'd1);
      end

      if (instruction_decode_occurred_i) begin
        instruction_execution_active_q           <= 1'b1;
        active_instruction_fu_type_q             <= decoded_fu_type_i;
        active_instruction_elapsed_cycle_count_q <= '0;
      end else if (pipeline_execute_instruction_discarded_i ||
                   instruction_completion_occurred) begin
        instruction_execution_active_q           <= 1'b0;
        active_instruction_fu_type_q             <= FU_NONE;
        active_instruction_elapsed_cycle_count_q <= '0;
      end else if (instruction_execution_active_q) begin
        active_instruction_elapsed_cycle_count_q <=
            active_instruction_elapsed_cycle_count_q + 64'd1;
      end
    end
  end

  // IFU metrics separate address-channel backpressure, memory response wait,
  // and downstream decode backpressure. These state occupancies may overlap on
  // a response cycle, so their percentages are independent diagnostic rates.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ifu_instruction_request_count_q    <= '0;
      ifu_instruction_response_count_q   <= '0;
      ifu_instruction_delivery_count_q   <= '0;
      ifu_discarded_response_count_q     <= '0;
      ifu_request_wait_cycle_count_q     <= '0;
      ifu_response_wait_cycle_count_q    <= '0;
      ifu_downstream_wait_cycle_count_q  <= '0;
      ifu_response_latency_cycle_sum_q   <= '0;
      ifu_response_elapsed_cycle_count_q <= '0;
      ifu_response_pending_q             <= 1'b0;
    end else begin
      if (ifu_instruction_request_waiting_i) begin
        ifu_request_wait_cycle_count_q <= ifu_request_wait_cycle_count_q + 64'd1;
      end
      if (ifu_downstream_waiting_i) begin
        ifu_downstream_wait_cycle_count_q <= ifu_downstream_wait_cycle_count_q + 64'd1;
      end
      if (ifu_instruction_delivery_occurred_i) begin
        ifu_instruction_delivery_count_q <= ifu_instruction_delivery_count_q + 64'd1;
      end
      if (ifu_instruction_response_discarded_occurred_i) begin
        ifu_discarded_response_count_q <= ifu_discarded_response_count_q + 64'd1;
      end

      if (ifu_instruction_request_occurred_i) begin
        ifu_instruction_request_count_q <= ifu_instruction_request_count_q + 64'd1;
      end

      if (ifu_response_pending_q) begin
        ifu_response_wait_cycle_count_q    <= ifu_response_wait_cycle_count_q + 64'd1;
        ifu_response_elapsed_cycle_count_q <= ifu_response_elapsed_cycle_count_q + 64'd1;
      end

      if (ifu_instruction_response_occurred_i) begin
        ifu_instruction_response_count_q <= ifu_instruction_response_count_q + 64'd1;
        ifu_response_latency_cycle_sum_q <= ifu_response_latency_cycle_sum_q +
                                            ifu_response_elapsed_cycle_count_q + 64'd1;
      end

      // 零气泡IFU允许旧响应离开和下一请求进入同拍发生。此时旧事务的延迟统计结束，
      // 但新事务已经开始，因此pending必须继续保持为1，并从0重新计算新事务延迟。
      // 将四种组合集中处理，避免两个独立if对pending/elapsed产生覆盖顺序依赖。
      unique case ({ifu_instruction_request_occurred_i,
                    ifu_instruction_response_occurred_i})
        2'b10: begin
          ifu_response_pending_q             <= 1'b1;
          ifu_response_elapsed_cycle_count_q <= '0;
        end

        2'b01: begin
          ifu_response_pending_q             <= 1'b0;
          ifu_response_elapsed_cycle_count_q <= '0;
        end

        2'b11: begin
          ifu_response_pending_q             <= 1'b1;
          ifu_response_elapsed_cycle_count_q <= '0;
        end

        default: ;
      endcase
    end
  end

  // LSU operation latency measures the CPU-visible interval from accepting an
  // LSU request to transferring its writeback result. It includes interconnect,
  // peripheral, and completion backpressure, which is the latency seen by this core.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      lsu_request_count_q                     <= '0;
      lsu_load_operation_count_q              <= '0;
      lsu_store_operation_count_q             <= '0;
      lsu_load_operation_latency_cycle_sum_q  <= '0;
      lsu_store_operation_latency_cycle_sum_q <= '0;
      lsu_operation_elapsed_cycle_count_q     <= '0;
      active_lsu_memory_cmd_q                 <= MEM_CMD_NONE;
      lsu_operation_active_q                  <= 1'b0;
    end else if (lsu_request_occurred_i && lsu_completion_occurred_i) begin
      lsu_request_count_q <= lsu_request_count_q + 64'd1;
      if (lsu_request_memory_cmd_i == MEM_CMD_LOAD) begin
        lsu_load_operation_count_q             <= lsu_load_operation_count_q + 64'd1;
        lsu_load_operation_latency_cycle_sum_q <= lsu_load_operation_latency_cycle_sum_q + 64'd1;
      end else if (lsu_request_memory_cmd_i == MEM_CMD_STORE) begin
        lsu_store_operation_count_q             <= lsu_store_operation_count_q + 64'd1;
        lsu_store_operation_latency_cycle_sum_q <= lsu_store_operation_latency_cycle_sum_q + 64'd1;
      end
      active_lsu_memory_cmd_q             <= MEM_CMD_NONE;
      lsu_operation_elapsed_cycle_count_q <= '0;
      lsu_operation_active_q              <= 1'b0;
    end else if (lsu_request_occurred_i) begin
      lsu_request_count_q                 <= lsu_request_count_q + 64'd1;
      active_lsu_memory_cmd_q             <= lsu_request_memory_cmd_i;
      lsu_operation_elapsed_cycle_count_q <= '0;
      lsu_operation_active_q              <= 1'b1;
    end else if (lsu_operation_active_q && lsu_completion_occurred_i) begin
      if (active_lsu_memory_cmd_q == MEM_CMD_LOAD) begin
        lsu_load_operation_count_q             <= lsu_load_operation_count_q + 64'd1;
        lsu_load_operation_latency_cycle_sum_q <=
                                                  lsu_load_operation_latency_cycle_sum_q +
                                                  lsu_operation_elapsed_cycle_count_q + 64'd1;
      end else if (active_lsu_memory_cmd_q == MEM_CMD_STORE) begin
        lsu_store_operation_count_q             <= lsu_store_operation_count_q + 64'd1;
        lsu_store_operation_latency_cycle_sum_q <=
                                                   lsu_store_operation_latency_cycle_sum_q +
                                                   lsu_operation_elapsed_cycle_count_q + 64'd1;
      end
      active_lsu_memory_cmd_q             <= MEM_CMD_NONE;
      lsu_operation_elapsed_cycle_count_q <= '0;
      lsu_operation_active_q              <= 1'b0;
    end else if (lsu_operation_active_q) begin
      lsu_operation_elapsed_cycle_count_q <= lsu_operation_elapsed_cycle_count_q + 64'd1;
    end
  end

  // Read-bus latency starts at AR handshake and ends at R handshake.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      lsu_read_bus_transaction_count_q   <= '0;
      lsu_read_bus_latency_cycle_sum_q   <= '0;
      lsu_read_bus_elapsed_cycle_count_q <= '0;
      lsu_read_response_pending_q        <= 1'b0;
    end else if (lsu_read_address_occurred_i && lsu_read_response_occurred_i) begin
      lsu_read_bus_transaction_count_q   <= lsu_read_bus_transaction_count_q + 64'd1;
      lsu_read_bus_latency_cycle_sum_q   <= lsu_read_bus_latency_cycle_sum_q + 64'd1;
      lsu_read_bus_elapsed_cycle_count_q <= '0;
      lsu_read_response_pending_q        <= 1'b0;
    end else if (lsu_read_address_occurred_i) begin
      lsu_read_bus_elapsed_cycle_count_q <= '0;
      lsu_read_response_pending_q        <= 1'b1;
    end else if (lsu_read_response_pending_q && lsu_read_response_occurred_i) begin
      lsu_read_bus_transaction_count_q   <= lsu_read_bus_transaction_count_q + 64'd1;
      lsu_read_bus_latency_cycle_sum_q   <= lsu_read_bus_latency_cycle_sum_q +
                                            lsu_read_bus_elapsed_cycle_count_q + 64'd1;
      lsu_read_bus_elapsed_cycle_count_q <= '0;
      lsu_read_response_pending_q        <= 1'b0;
    end else if (lsu_read_response_pending_q) begin
      lsu_read_bus_elapsed_cycle_count_q <= lsu_read_bus_elapsed_cycle_count_q + 64'd1;
    end
  end

  // AXI4 AW and W are independent. Store response latency begins only after
  // both have handshaken, regardless of which channel completed first.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      lsu_write_bus_transaction_count_q      <= '0;
      lsu_write_bus_latency_cycle_sum_q      <= '0;
      lsu_write_bus_elapsed_cycle_count_q    <= '0;
      lsu_write_response_pending_q           <= 1'b0;
      lsu_write_address_handshake_occurred_q <= 1'b0;
      lsu_write_data_handshake_occurred_q    <= 1'b0;
    end else begin
      if (lsu_write_address_occurred_i) begin
        lsu_write_address_handshake_occurred_q <= 1'b1;
      end
      if (lsu_write_data_occurred_i) begin
        lsu_write_data_handshake_occurred_q <= 1'b1;
      end

      if (!lsu_write_response_pending_q && lsu_write_request_channels_handshake_occurred) begin
        lsu_write_response_pending_q        <= 1'b1;
        lsu_write_bus_elapsed_cycle_count_q <= '0;
      end else if (lsu_write_response_pending_q) begin
        lsu_write_bus_elapsed_cycle_count_q <= lsu_write_bus_elapsed_cycle_count_q + 64'd1;
      end

      if (lsu_write_response_occurred_i) begin
        lsu_write_bus_transaction_count_q      <= lsu_write_bus_transaction_count_q + 64'd1;
        lsu_write_bus_latency_cycle_sum_q      <= lsu_write_bus_latency_cycle_sum_q +
                                                  lsu_write_bus_elapsed_cycle_count_q + 64'd1;
        lsu_write_bus_elapsed_cycle_count_q    <= '0;
        lsu_write_response_pending_q           <= 1'b0;
        lsu_write_address_handshake_occurred_q <= 1'b0;
        lsu_write_data_handshake_occurred_q    <= 1'b0;
      end
    end
  end

  final begin
    $display("");
    $display("================ NPC performance counters ================");
    $display("active core cycles                 : %0d", active_cycle_count_q);
    $display("decoded instructions               : %0d", decoded_instruction_count_q);
    $display("retired instructions               : %0d", retired_instruction_count_q);
    $display("IPC                                : %.6f", calculate_ratio(
             retired_instruction_count_q, active_cycle_count_q));
    $display("");
    $display("instruction class        count       ratio       average execution cycles");
    $display("integer              %10d  %8.3f%%  %12.3f", integer_instruction_count_q,
             calculate_percentage(integer_instruction_count_q, decoded_instruction_count_q),
             calculate_average_cycles(integer_execution_cycle_sum_q, integer_instruction_count_q));
    $display("branch/jump          %10d  %8.3f%%  %12.3f", branch_instruction_count_q,
             calculate_percentage(branch_instruction_count_q, decoded_instruction_count_q),
             calculate_average_cycles(branch_execution_cycle_sum_q, branch_instruction_count_q));
    $display("load/store           %10d  %8.3f%%  %12.3f", memory_instruction_count_q,
             calculate_percentage(memory_instruction_count_q, decoded_instruction_count_q),
             calculate_average_cycles(memory_execution_cycle_sum_q, memory_instruction_count_q));
    $display("  load               %10d  %8.3f%%", load_instruction_count_q, calculate_percentage(
             load_instruction_count_q, decoded_instruction_count_q));
    $display("  store              %10d  %8.3f%%", store_instruction_count_q, calculate_percentage(
             store_instruction_count_q, decoded_instruction_count_q));
    $display("CSR                   %10d  %8.3f%%  %12.3f", csr_instruction_count_q,
             calculate_percentage(csr_instruction_count_q, decoded_instruction_count_q),
             calculate_average_cycles(csr_execution_cycle_sum_q, csr_instruction_count_q));
    $display("system                %10d  %8.3f%%  %12.3f", system_instruction_count_q,
             calculate_percentage(system_instruction_count_q, decoded_instruction_count_q),
             calculate_average_cycles(system_execution_cycle_sum_q, system_instruction_count_q));
    $display("unclassified          %10d  %8.3f%%  %12.3f", unclassified_instruction_count_q,
             calculate_percentage(unclassified_instruction_count_q, decoded_instruction_count_q),
             calculate_average_cycles(unclassified_execution_cycle_sum_q,
                                      unclassified_instruction_count_q));
    $display("");
    $display("IFU requests / responses / deliveries : %0d / %0d / %0d",
             ifu_instruction_request_count_q, ifu_instruction_response_count_q,
             ifu_instruction_delivery_count_q);
    $display("IFU average response latency           : %.3f cycles", calculate_average_cycles(
             ifu_response_latency_cycle_sum_q, ifu_instruction_response_count_q));
    $display("IFU AR backpressure cycles             : %0d (%.3f%%)",
             ifu_request_wait_cycle_count_q, calculate_percentage(ifu_request_wait_cycle_count_q,
                                                                  active_cycle_count_q));
    $display("IFU response-wait cycles               : %0d (%.3f%%)",
             ifu_response_wait_cycle_count_q, calculate_percentage(ifu_response_wait_cycle_count_q,
                                                                   active_cycle_count_q));
    $display("IFU downstream-backpressure cycles     : %0d (%.3f%%)",
             ifu_downstream_wait_cycle_count_q, calculate_percentage(
             ifu_downstream_wait_cycle_count_q, active_cycle_count_q));
    $display("IFU discarded wrong-path responses     : %0d", ifu_discarded_response_count_q);
    $display("");
    $display("LSU requests / completions             : %0d / %0d", lsu_request_count_q,
             lsu_completion_count_q);
    $display("LSU load operation average latency     : %.3f cycles (%0d operations)",
             calculate_average_cycles(lsu_load_operation_latency_cycle_sum_q,
                                      lsu_load_operation_count_q), lsu_load_operation_count_q);
    $display("LSU store operation average latency    : %.3f cycles (%0d operations)",
             calculate_average_cycles(lsu_store_operation_latency_cycle_sum_q,
                                      lsu_store_operation_count_q), lsu_store_operation_count_q);
    $display("LSU AXI read average latency           : %.3f cycles (%0d transactions)",
             calculate_average_cycles(lsu_read_bus_latency_cycle_sum_q,
                                      lsu_read_bus_transaction_count_q),
             lsu_read_bus_transaction_count_q);
    $display("LSU AXI write-response average latency : %.3f cycles (%0d transactions)",
             calculate_average_cycles(lsu_write_bus_latency_cycle_sum_q,
                                      lsu_write_bus_transaction_count_q),
             lsu_write_bus_transaction_count_q);
    $display("EXU / LSU completions                  : %0d / %0d", exu_completion_count_q,
             lsu_completion_count_q);
    $display("");
    $display("exclusive pipeline issue-slot attribution");
    $display("  issued instructions                 : %0d (%.3f%%)",
             decoded_instruction_count_q,
             calculate_percentage(decoded_instruction_count_q, active_cycle_count_q));
    $display("  control recovery stalls             : %0d (%.3f%%)",
             control_recovery_stall_cycle_count_q,
             calculate_percentage(control_recovery_stall_cycle_count_q,
                                  active_cycle_count_q));
    $display("  LSU structural stalls               : %0d (%.3f%%)",
             lsu_structural_stall_cycle_count_q,
             calculate_percentage(lsu_structural_stall_cycle_count_q, active_cycle_count_q));
    $display("  unresolved RAW stalls               : %0d (%.3f%%)",
             raw_dependency_stall_cycle_count_q,
             calculate_percentage(raw_dependency_stall_cycle_count_q, active_cycle_count_q));
    $display("  serializing stalls                  : %0d (%.3f%%)",
             serializing_stall_cycle_count_q,
             calculate_percentage(serializing_stall_cycle_count_q, active_cycle_count_q));
    $display("  frontend supply stalls              : %0d (%.3f%%)",
             frontend_supply_stall_cycle_count_q,
             calculate_percentage(frontend_supply_stall_cycle_count_q, active_cycle_count_q));
    $display("    request backpressure              : %0d (%.3f%%)",
             frontend_request_backpressure_stall_cycle_count_q,
             calculate_percentage(frontend_request_backpressure_stall_cycle_count_q,
                                  active_cycle_count_q));
    $display("    I-cache miss service              : %0d (%.3f%%)",
             frontend_cache_miss_service_stall_cycle_count_q,
             calculate_percentage(frontend_cache_miss_service_stall_cycle_count_q,
                                  active_cycle_count_q));
    $display("    lookup response in flight         : %0d (%.3f%%)",
             frontend_lookup_response_stall_cycle_count_q,
             calculate_percentage(frontend_lookup_response_stall_cycle_count_q,
                                  active_cycle_count_q));
    $display("    request launch or delivery gap    : %0d (%.3f%%)",
             frontend_request_launch_or_delivery_gap_cycle_count_q,
             calculate_percentage(frontend_request_launch_or_delivery_gap_cycle_count_q,
                                  active_cycle_count_q));
    $display("  other empty issue slots             : %0d (%.3f%%)",
             other_no_issue_cycle_count_q,
             calculate_percentage(other_no_issue_cycle_count_q, active_cycle_count_q));
    $display("recovery redirects / taken fetch predictions / EX corrections: %0d / %0d / %0d",
             pipeline_control_flush_count_q, fetch_taken_prediction_count_q,
             execute_misprediction_redirect_count_q);
    $display("actual EX corrections by branch / JAL / JALR          : %0d / %0d / %0d",
             conditional_branch_correction_count_q, direct_jump_correction_count_q,
             indirect_jump_correction_count_q);
    $display("pipeline execute discards             : %0d", pipeline_execute_discard_count_q);
    $display("");
    $display("resolved control-flow profile");
    $display("conditional branches / taken        : %0d / %0d (%.3f%% taken)",
             conditional_branch_count_q, conditional_branch_taken_count_q,
             calculate_percentage(conditional_branch_taken_count_q, conditional_branch_count_q));
    $display("  backward / taken                  : %0d / %0d (%.3f%% taken)",
             backward_branch_count_q, backward_branch_taken_count_q,
             calculate_percentage(backward_branch_taken_count_q, backward_branch_count_q));
    $display("  forward / taken                   : %0d / %0d (%.3f%% taken)",
             forward_branch_count_q, forward_branch_taken_count_q,
             calculate_percentage(forward_branch_taken_count_q, forward_branch_count_q));
    $display("direct / indirect jumps             : %0d / %0d", direct_jump_count_q,
             indirect_jump_count_q);
    $display("always-not-taken prediction errors  : %0d (%.3f%% of control flow)",
             always_not_taken_prediction_error_count_q,
             calculate_percentage(always_not_taken_prediction_error_count_q,
                                  conditional_branch_count_q + direct_jump_count_q +
                                  indirect_jump_count_q));
    $display("BTFNT+JAL prediction errors          : %0d (%.3f%% of control flow)",
             btfnt_prediction_error_count_q,
             calculate_percentage(btfnt_prediction_error_count_q,
                                  conditional_branch_count_q + direct_jump_count_q +
                                  indirect_jump_count_q));
    $display("16-entry BHT+JAL errors              : %0d (conditional %0d + JALR %0d)",
             bht_16_prediction_error_count_q + indirect_jump_count_q,
             bht_16_prediction_error_count_q, indirect_jump_count_q);
    $display("64-entry BHT+JAL errors              : %0d (conditional %0d + JALR %0d)",
             bht_64_prediction_error_count_q + indirect_jump_count_q,
             bht_64_prediction_error_count_q, indirect_jump_count_q);
    $display("");
    $display("idealized upper-bound estimates");
    $display("memory execution excess cycles        : %.3f",
             calculate_memory_execution_excess_cycles());
    $display("I-cache critical miss excess cycles   : %.3f",
             calculate_icache_miss_penalty_cycle_sum());
    $display("oracle 1-cycle data memory / speedup   : %.3f / %.3fx",
             calculate_oracle_single_cycle_data_memory_cycle_count(), calculate_speedup(
             calculate_oracle_single_cycle_data_memory_cycle_count()));
    $display("ideal single-issue pipeline cycles     : %.3f / %.3fx",
             calculate_ideal_single_issue_pipeline_cycle_count(), calculate_speedup(
             calculate_ideal_single_issue_pipeline_cycle_count()));
    $display("ideal pipeline + oracle data memory    : %.3f / %.3fx",
             calculate_ideal_pipeline_and_oracle_data_memory_cycle_count(), calculate_speedup(
             calculate_ideal_pipeline_and_oracle_data_memory_cycle_count()));
    $display("==========================================================");

    if (decoded_instruction_count_q != ifu_instruction_delivery_count_q) begin
      $display("PERF CHECK: decoded count differs from IFU-delivered count");
    end
    if (decoded_instruction_count_q !=
        integer_instruction_count_q + branch_instruction_count_q +
        memory_instruction_count_q + csr_instruction_count_q +
        system_instruction_count_q + unclassified_instruction_count_q) begin
      $display("PERF CHECK: instruction-class sum differs from decoded count");
    end
    if (memory_instruction_count_q != load_instruction_count_q + store_instruction_count_q) begin
      $display("PERF CHECK: load/store sum differs from memory-instruction count");
    end
    if (lsu_request_count_q != lsu_completion_count_q) begin
      $display("PERF CHECK: LSU request count differs from LSU completion count");
    end
    if (active_cycle_count_q !=
        decoded_instruction_count_q +
        control_recovery_stall_cycle_count_q +
        lsu_structural_stall_cycle_count_q + raw_dependency_stall_cycle_count_q +
        serializing_stall_cycle_count_q + frontend_supply_stall_cycle_count_q +
        other_no_issue_cycle_count_q) begin
      $display("PERF CHECK: exclusive issue-slot categories do not cover all active cycles");
    end
    if (frontend_supply_stall_cycle_count_q !=
        frontend_request_backpressure_stall_cycle_count_q +
        frontend_cache_miss_service_stall_cycle_count_q +
        frontend_lookup_response_stall_cycle_count_q +
        frontend_request_launch_or_delivery_gap_cycle_count_q) begin
      $display("PERF CHECK: frontend stall subcategories do not cover all frontend stalls");
    end
  end

endmodule

`endif
