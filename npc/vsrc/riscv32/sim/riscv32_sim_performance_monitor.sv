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

    input logic     instruction_decode_occurred_i,
    input fu_type_e decoded_fu_type_i,
    input mem_cmd_e decoded_memory_cmd_i,
    input logic     exu_completion_occurred_i,
    input logic     lsu_completion_occurred_i,
    input logic     instruction_retirement_occurred_i,

    input logic     lsu_request_occurred_i,
    input mem_cmd_e lsu_request_memory_cmd_i,
    input logic     lsu_read_address_occurred_i,
    input logic     lsu_read_response_occurred_i,
    input logic     lsu_write_address_occurred_i,
    input logic     lsu_write_data_occurred_i,
    input logic     lsu_write_response_occurred_i
);
  logic [63:0] active_cycle_count_q;
  logic [63:0] decoded_instruction_count_q;
  logic [63:0] retired_instruction_count_q;
  logic [63:0] exu_completion_count_q;
  logic [63:0] lsu_completion_count_q;

  logic [63:0] integer_instruction_count_q;
  logic [63:0] branch_instruction_count_q;
  logic [63:0] memory_instruction_count_q;
  logic [63:0] load_instruction_count_q;
  logic [63:0] store_instruction_count_q;
  logic [63:0] csr_instruction_count_q;
  logic [63:0] system_instruction_count_q;
  logic [63:0] unclassified_instruction_count_q;

  logic [63:0] integer_execution_cycle_sum_q;
  logic [63:0] branch_execution_cycle_sum_q;
  logic [63:0] memory_execution_cycle_sum_q;
  logic [63:0] csr_execution_cycle_sum_q;
  logic [63:0] system_execution_cycle_sum_q;
  logic [63:0] unclassified_execution_cycle_sum_q;

  logic        instruction_execution_active_q;
  fu_type_e    active_instruction_fu_type_q;
  logic [63:0] active_instruction_elapsed_cycle_count_q;

  logic [63:0] ifu_instruction_request_count_q;
  logic [63:0] ifu_instruction_response_count_q;
  logic [63:0] ifu_instruction_delivery_count_q;
  logic [63:0] ifu_discarded_response_count_q;
  logic [63:0] ifu_request_wait_cycle_count_q;
  logic [63:0] ifu_response_wait_cycle_count_q;
  logic [63:0] ifu_downstream_wait_cycle_count_q;
  logic [63:0] ifu_response_latency_cycle_sum_q;
  logic [63:0] ifu_response_elapsed_cycle_count_q;
  logic        ifu_response_pending_q;

  logic [63:0] lsu_request_count_q;
  logic [63:0] lsu_load_operation_count_q;
  logic [63:0] lsu_store_operation_count_q;
  logic [63:0] lsu_load_operation_latency_cycle_sum_q;
  logic [63:0] lsu_store_operation_latency_cycle_sum_q;
  logic [63:0] lsu_operation_elapsed_cycle_count_q;
  mem_cmd_e    active_lsu_memory_cmd_q;
  logic        lsu_operation_active_q;

  logic [63:0] lsu_read_bus_transaction_count_q;
  logic [63:0] lsu_read_bus_latency_cycle_sum_q;
  logic [63:0] lsu_read_bus_elapsed_cycle_count_q;
  logic        lsu_read_response_pending_q;

  logic [63:0] lsu_write_bus_transaction_count_q;
  logic [63:0] lsu_write_bus_latency_cycle_sum_q;
  logic [63:0] lsu_write_bus_elapsed_cycle_count_q;
  logic        lsu_write_response_pending_q;
  logic        lsu_write_address_handshake_occurred_q;
  logic        lsu_write_data_handshake_occurred_q;

  logic instruction_completion_occurred;
  logic lsu_write_request_channels_handshake_occurred;

  assign instruction_completion_occurred = exu_completion_occurred_i ||
                                            lsu_completion_occurred_i;

  assign lsu_write_request_channels_handshake_occurred =
      (lsu_write_address_handshake_occurred_q || lsu_write_address_occurred_i) &&
      (lsu_write_data_handshake_occurred_q || lsu_write_data_occurred_i);

  function automatic real calculate_ratio(
      input logic [63:0] numerator,
      input logic [63:0] denominator
  );
    if (denominator == 0) begin
      return 0.0;
    end
    return real'(numerator) / real'(denominator);
  endfunction

  function automatic real calculate_percentage(
      input logic [63:0] event_count,
      input logic [63:0] total_count
  );
    if (total_count == 0) begin
      return 0.0;
    end
    return (100.0 * real'(event_count)) / real'(total_count);
  endfunction

  function automatic real calculate_average_cycles(
      input logic [63:0] cycle_sum,
      input logic [63:0] event_count
  );
    if (event_count == 0) begin
      return 0.0;
    end
    return real'(cycle_sum) / real'(event_count);
  endfunction

  task automatic add_instruction_execution_cycles(
      input fu_type_e    instruction_fu_type,
      input logic [63:0] execution_cycle_count
  );
    unique case (instruction_fu_type)
      FU_INT: begin
        integer_execution_cycle_sum_q <= integer_execution_cycle_sum_q +
                                         execution_cycle_count;
      end
      FU_BRANCH: begin
        branch_execution_cycle_sum_q <= branch_execution_cycle_sum_q +
                                        execution_cycle_count;
      end
      FU_LSU: begin
        memory_execution_cycle_sum_q <= memory_execution_cycle_sum_q +
                                        execution_cycle_count;
      end
      FU_CSR: begin
        csr_execution_cycle_sum_q <= csr_execution_cycle_sum_q + execution_cycle_count;
      end
      FU_SYSTEM: begin
        system_execution_cycle_sum_q <= system_execution_cycle_sum_q +
                                        execution_cycle_count;
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
      active_cycle_count_q               <= '0;
      decoded_instruction_count_q        <= '0;
      retired_instruction_count_q        <= '0;
      exu_completion_count_q             <= '0;
      lsu_completion_count_q             <= '0;
      integer_instruction_count_q        <= '0;
      branch_instruction_count_q         <= '0;
      memory_instruction_count_q         <= '0;
      load_instruction_count_q           <= '0;
      store_instruction_count_q          <= '0;
      csr_instruction_count_q            <= '0;
      system_instruction_count_q         <= '0;
      unclassified_instruction_count_q   <= '0;
    end else begin
      active_cycle_count_q <= active_cycle_count_q + 64'd1;

      if (instruction_decode_occurred_i) begin
        decoded_instruction_count_q <= decoded_instruction_count_q + 64'd1;
        unique case (decoded_fu_type_i)
          FU_INT:    integer_instruction_count_q <= integer_instruction_count_q + 64'd1;
          FU_BRANCH: branch_instruction_count_q  <= branch_instruction_count_q + 64'd1;
          FU_LSU: begin
            memory_instruction_count_q <= memory_instruction_count_q + 64'd1;
            if (decoded_memory_cmd_i == MEM_CMD_LOAD) begin
              load_instruction_count_q <= load_instruction_count_q + 64'd1;
            end else if (decoded_memory_cmd_i == MEM_CMD_STORE) begin
              store_instruction_count_q <= store_instruction_count_q + 64'd1;
            end
          end
          FU_CSR:    csr_instruction_count_q    <= csr_instruction_count_q + 64'd1;
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
    end
  end

  // Execution latency starts when IDU transfers a uop and ends when EXU or LSU
  // transfers its result. The current core has one in-flight execution slot.
  // A future out-of-order core must replace this scalar state with timestamps
  // indexed by ROB tag so multiple instructions can be measured concurrently.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      instruction_execution_active_q             <= 1'b0;
      active_instruction_fu_type_q               <= FU_NONE;
      active_instruction_elapsed_cycle_count_q   <= '0;
      integer_execution_cycle_sum_q              <= '0;
      branch_execution_cycle_sum_q               <= '0;
      memory_execution_cycle_sum_q               <= '0;
      csr_execution_cycle_sum_q                  <= '0;
      system_execution_cycle_sum_q               <= '0;
      unclassified_execution_cycle_sum_q         <= '0;
    end else if (instruction_decode_occurred_i && instruction_completion_occurred) begin
      // A combinational EXU or local LSU completion occupies one measured cycle.
      add_instruction_execution_cycles(decoded_fu_type_i, 64'd1);
      instruction_execution_active_q           <= 1'b0;
      active_instruction_fu_type_q             <= FU_NONE;
      active_instruction_elapsed_cycle_count_q <= '0;
    end else if (instruction_decode_occurred_i) begin
      instruction_execution_active_q           <= 1'b1;
      active_instruction_fu_type_q             <= decoded_fu_type_i;
      active_instruction_elapsed_cycle_count_q <= '0;
    end else if (instruction_execution_active_q && instruction_completion_occurred) begin
      add_instruction_execution_cycles(active_instruction_fu_type_q,
                                       active_instruction_elapsed_cycle_count_q + 64'd1);
      instruction_execution_active_q           <= 1'b0;
      active_instruction_fu_type_q             <= FU_NONE;
      active_instruction_elapsed_cycle_count_q <= '0;
    end else if (instruction_execution_active_q) begin
      active_instruction_elapsed_cycle_count_q <=
          active_instruction_elapsed_cycle_count_q + 64'd1;
    end
  end

  // IFU metrics separate address-channel backpressure, memory response wait,
  // and downstream decode backpressure. These state occupancies may overlap on
  // a response cycle, so their percentages are independent diagnostic rates.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ifu_instruction_request_count_q             <= '0;
      ifu_instruction_response_count_q            <= '0;
      ifu_instruction_delivery_count_q            <= '0;
      ifu_discarded_response_count_q               <= '0;
      ifu_request_wait_cycle_count_q               <= '0;
      ifu_response_wait_cycle_count_q              <= '0;
      ifu_downstream_wait_cycle_count_q            <= '0;
      ifu_response_latency_cycle_sum_q             <= '0;
      ifu_response_elapsed_cycle_count_q           <= '0;
      ifu_response_pending_q                       <= 1'b0;
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
        ifu_instruction_request_count_q           <= ifu_instruction_request_count_q + 64'd1;
        ifu_response_pending_q                     <= 1'b1;
        ifu_response_elapsed_cycle_count_q         <= '0;
      end

      if (ifu_response_pending_q) begin
        ifu_response_wait_cycle_count_q      <= ifu_response_wait_cycle_count_q + 64'd1;
        ifu_response_elapsed_cycle_count_q   <= ifu_response_elapsed_cycle_count_q + 64'd1;
      end

      if (ifu_instruction_response_occurred_i) begin
        ifu_instruction_response_count_q    <= ifu_instruction_response_count_q + 64'd1;
        ifu_response_latency_cycle_sum_q    <= ifu_response_latency_cycle_sum_q +
                                               ifu_response_elapsed_cycle_count_q + 64'd1;
        ifu_response_pending_q              <= 1'b0;
        ifu_response_elapsed_cycle_count_q  <= '0;
      end
    end
  end

  // LSU operation latency measures the CPU-visible interval from accepting an
  // LSU request to transferring its writeback result. It includes interconnect,
  // peripheral, and completion backpressure, which is the latency seen by this core.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      lsu_request_count_q                      <= '0;
      lsu_load_operation_count_q               <= '0;
      lsu_store_operation_count_q              <= '0;
      lsu_load_operation_latency_cycle_sum_q   <= '0;
      lsu_store_operation_latency_cycle_sum_q  <= '0;
      lsu_operation_elapsed_cycle_count_q      <= '0;
      active_lsu_memory_cmd_q                  <= MEM_CMD_NONE;
      lsu_operation_active_q                   <= 1'b0;
    end else if (lsu_request_occurred_i && lsu_completion_occurred_i) begin
      lsu_request_count_q <= lsu_request_count_q + 64'd1;
      if (lsu_request_memory_cmd_i == MEM_CMD_LOAD) begin
        lsu_load_operation_count_q <= lsu_load_operation_count_q + 64'd1;
        lsu_load_operation_latency_cycle_sum_q <=
            lsu_load_operation_latency_cycle_sum_q + 64'd1;
      end else if (lsu_request_memory_cmd_i == MEM_CMD_STORE) begin
        lsu_store_operation_count_q <= lsu_store_operation_count_q + 64'd1;
        lsu_store_operation_latency_cycle_sum_q <=
            lsu_store_operation_latency_cycle_sum_q + 64'd1;
      end
      active_lsu_memory_cmd_q             <= MEM_CMD_NONE;
      lsu_operation_elapsed_cycle_count_q <= '0;
      lsu_operation_active_q              <= 1'b0;
    end else if (lsu_request_occurred_i) begin
      lsu_request_count_q                  <= lsu_request_count_q + 64'd1;
      active_lsu_memory_cmd_q              <= lsu_request_memory_cmd_i;
      lsu_operation_elapsed_cycle_count_q  <= '0;
      lsu_operation_active_q               <= 1'b1;
    end else if (lsu_operation_active_q && lsu_completion_occurred_i) begin
      if (active_lsu_memory_cmd_q == MEM_CMD_LOAD) begin
        lsu_load_operation_count_q <= lsu_load_operation_count_q + 64'd1;
        lsu_load_operation_latency_cycle_sum_q <=
            lsu_load_operation_latency_cycle_sum_q +
            lsu_operation_elapsed_cycle_count_q + 64'd1;
      end else if (active_lsu_memory_cmd_q == MEM_CMD_STORE) begin
        lsu_store_operation_count_q <= lsu_store_operation_count_q + 64'd1;
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
      lsu_read_bus_transaction_count_q       <= '0;
      lsu_read_bus_latency_cycle_sum_q       <= '0;
      lsu_read_bus_elapsed_cycle_count_q     <= '0;
      lsu_read_response_pending_q            <= 1'b0;
    end else if (lsu_read_address_occurred_i && lsu_read_response_occurred_i) begin
      lsu_read_bus_transaction_count_q   <= lsu_read_bus_transaction_count_q + 64'd1;
      lsu_read_bus_latency_cycle_sum_q   <= lsu_read_bus_latency_cycle_sum_q + 64'd1;
      lsu_read_bus_elapsed_cycle_count_q <= '0;
      lsu_read_response_pending_q        <= 1'b0;
    end else if (lsu_read_address_occurred_i) begin
      lsu_read_bus_elapsed_cycle_count_q <= '0;
      lsu_read_response_pending_q        <= 1'b1;
    end else if (lsu_read_response_pending_q && lsu_read_response_occurred_i) begin
      lsu_read_bus_transaction_count_q <= lsu_read_bus_transaction_count_q + 64'd1;
      lsu_read_bus_latency_cycle_sum_q <= lsu_read_bus_latency_cycle_sum_q +
                                          lsu_read_bus_elapsed_cycle_count_q + 64'd1;
      lsu_read_bus_elapsed_cycle_count_q <= '0;
      lsu_read_response_pending_q        <= 1'b0;
    end else if (lsu_read_response_pending_q) begin
      lsu_read_bus_elapsed_cycle_count_q <= lsu_read_bus_elapsed_cycle_count_q + 64'd1;
    end
  end

  // AXI-Lite AW and W are independent. Store response latency begins only after
  // both have handshaken, regardless of which channel completed first.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      lsu_write_bus_transaction_count_q     <= '0;
      lsu_write_bus_latency_cycle_sum_q     <= '0;
      lsu_write_bus_elapsed_cycle_count_q   <= '0;
      lsu_write_response_pending_q          <= 1'b0;
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
        lsu_write_bus_transaction_count_q <= lsu_write_bus_transaction_count_q + 64'd1;
        lsu_write_bus_latency_cycle_sum_q <= lsu_write_bus_latency_cycle_sum_q +
                                             lsu_write_bus_elapsed_cycle_count_q + 64'd1;
        lsu_write_bus_elapsed_cycle_count_q <= '0;
        lsu_write_response_pending_q        <= 1'b0;
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
    $display("IPC                                : %.6f",
             calculate_ratio(retired_instruction_count_q, active_cycle_count_q));
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
    $display("  load               %10d  %8.3f%%", load_instruction_count_q,
             calculate_percentage(load_instruction_count_q, decoded_instruction_count_q));
    $display("  store              %10d  %8.3f%%", store_instruction_count_q,
             calculate_percentage(store_instruction_count_q, decoded_instruction_count_q));
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
    $display("IFU average response latency           : %.3f cycles",
             calculate_average_cycles(ifu_response_latency_cycle_sum_q,
                                      ifu_instruction_response_count_q));
    $display("IFU AR backpressure cycles             : %0d (%.3f%%)",
             ifu_request_wait_cycle_count_q,
             calculate_percentage(ifu_request_wait_cycle_count_q, active_cycle_count_q));
    $display("IFU response-wait cycles               : %0d (%.3f%%)",
             ifu_response_wait_cycle_count_q,
             calculate_percentage(ifu_response_wait_cycle_count_q, active_cycle_count_q));
    $display("IFU downstream-backpressure cycles     : %0d (%.3f%%)",
             ifu_downstream_wait_cycle_count_q,
             calculate_percentage(ifu_downstream_wait_cycle_count_q, active_cycle_count_q));
    $display("IFU discarded wrong-path responses     : %0d", ifu_discarded_response_count_q);
    $display("");
    $display("LSU requests / completions             : %0d / %0d", lsu_request_count_q,
             lsu_completion_count_q);
    $display("LSU load operation average latency     : %.3f cycles (%0d operations)",
             calculate_average_cycles(lsu_load_operation_latency_cycle_sum_q,
                                      lsu_load_operation_count_q),
             lsu_load_operation_count_q);
    $display("LSU store operation average latency    : %.3f cycles (%0d operations)",
             calculate_average_cycles(lsu_store_operation_latency_cycle_sum_q,
                                      lsu_store_operation_count_q),
             lsu_store_operation_count_q);
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
  end

endmodule

`endif
