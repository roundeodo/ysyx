`ifdef VERILATOR

module riscv32_sim_performance_monitor
  import riscv32_pkg::*;
(
    input logic clk_i,
    input logic rst_ni,

    input logic     ifu_instruction_delivery_occurred_i,
    input logic     lsu_load_data_response_occurred_i,
    input logic     exu_completion_occurred_i,
    input logic     lsu_completion_occurred_i,
    input logic     instruction_decode_occurred_i,
    input fu_type_e decoded_fu_type_i,
    input logic     instruction_retirement_occurred_i
);
  logic [63:0] active_cycle_count_q;
  logic [63:0] ifu_instruction_delivery_count_q;
  logic [63:0] lsu_load_data_response_count_q;
  logic [63:0] exu_completion_count_q;
  logic [63:0] lsu_completion_count_q;
  logic [63:0] decoded_instruction_count_q;
  logic [63:0] retired_instruction_count_q;

  logic [63:0] integer_instruction_count_q;
  logic [63:0] branch_instruction_count_q;
  logic [63:0] memory_instruction_count_q;
  logic [63:0] csr_instruction_count_q;
  logic [63:0] system_instruction_count_q;
  logic [63:0] unclassified_instruction_count_q;

  // Stage counters observe completed handshakes. Counting VALID alone would
  // count the same transaction repeatedly while READY is low.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      active_cycle_count_q               <= '0;
      ifu_instruction_delivery_count_q   <= '0;
      lsu_load_data_response_count_q     <= '0;
      exu_completion_count_q             <= '0;
      lsu_completion_count_q             <= '0;
      decoded_instruction_count_q        <= '0;
      retired_instruction_count_q        <= '0;
    end else begin
      active_cycle_count_q <= active_cycle_count_q + 64'd1;

      if (ifu_instruction_delivery_occurred_i) begin
        ifu_instruction_delivery_count_q <= ifu_instruction_delivery_count_q + 64'd1;
      end
      if (lsu_load_data_response_occurred_i) begin
        lsu_load_data_response_count_q <= lsu_load_data_response_count_q + 64'd1;
      end
      if (exu_completion_occurred_i) begin
        exu_completion_count_q <= exu_completion_count_q + 64'd1;
      end
      if (lsu_completion_occurred_i) begin
        lsu_completion_count_q <= lsu_completion_count_q + 64'd1;
      end
      if (instruction_decode_occurred_i) begin
        decoded_instruction_count_q <= decoded_instruction_count_q + 64'd1;
      end
      if (instruction_retirement_occurred_i) begin
        retired_instruction_count_q <= retired_instruction_count_q + 64'd1;
      end
    end
  end

  // Instruction classes are sampled only when IDU actually transfers one uop
  // downstream. Therefore each dynamic instruction contributes to one class.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      integer_instruction_count_q      <= '0;
      branch_instruction_count_q       <= '0;
      memory_instruction_count_q       <= '0;
      csr_instruction_count_q          <= '0;
      system_instruction_count_q       <= '0;
      unclassified_instruction_count_q <= '0;
    end else if (instruction_decode_occurred_i) begin
      unique case (decoded_fu_type_i)
        FU_INT:    integer_instruction_count_q <= integer_instruction_count_q + 64'd1;
        FU_BRANCH: branch_instruction_count_q  <= branch_instruction_count_q + 64'd1;
        FU_LSU:    memory_instruction_count_q  <= memory_instruction_count_q + 64'd1;
        FU_CSR:    csr_instruction_count_q     <= csr_instruction_count_q + 64'd1;
        FU_SYSTEM: system_instruction_count_q  <= system_instruction_count_q + 64'd1;
        default: begin
          unclassified_instruction_count_q <= unclassified_instruction_count_q + 64'd1;
        end
      endcase
    end
  end

  final begin
    $display("");
    $display("========== NPC performance counters ==========");
    $display("active core cycles           : %0d", active_cycle_count_q);
    $display("IFU instructions delivered   : %0d", ifu_instruction_delivery_count_q);
    $display("LSU load data responses      : %0d", lsu_load_data_response_count_q);
    $display("EXU completions              : %0d", exu_completion_count_q);
    $display("LSU completions              : %0d", lsu_completion_count_q);
    $display("decoded instructions         : %0d", decoded_instruction_count_q);
    $display("retired instructions         : %0d", retired_instruction_count_q);
    $display("  integer                    : %0d", integer_instruction_count_q);
    $display("  branch/jump                : %0d", branch_instruction_count_q);
    $display("  load/store                 : %0d", memory_instruction_count_q);
    $display("  CSR                        : %0d", csr_instruction_count_q);
    $display("  system                     : %0d", system_instruction_count_q);
    $display("  unclassified               : %0d", unclassified_instruction_count_q);
    $display("IPC numerator/denominator    : %0d / %0d", retired_instruction_count_q,
             active_cycle_count_q);
    $display("==============================================");

    if (decoded_instruction_count_q != ifu_instruction_delivery_count_q) begin
      $display("PERF CHECK: decoded count differs from IFU-delivered count");
    end
    if (decoded_instruction_count_q !=
        integer_instruction_count_q + branch_instruction_count_q +
        memory_instruction_count_q + csr_instruction_count_q +
        system_instruction_count_q + unclassified_instruction_count_q) begin
      $display("PERF CHECK: instruction-class sum differs from decoded count");
    end
  end

endmodule

`endif
