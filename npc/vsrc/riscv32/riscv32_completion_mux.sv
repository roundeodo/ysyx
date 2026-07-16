module riscv32_completion_mux
  import riscv32_pkg::*;
(
    /* verilator lint_off UNUSEDSIGNAL */
    input  execute_result_t direct_result_i,
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic            direct_valid_i,
    output logic            direct_ready_o,

    input  writeback_result_t memory_result_i,
    input  logic              memory_valid_i,
    output logic              memory_ready_o,

    output writeback_result_t writeback_result_o,
    output logic              writeback_valid_o,
    input  logic              writeback_ready_i
);
  writeback_result_t direct_writeback;

  always_comb begin
    direct_writeback              = '0;
    direct_writeback.uop          = direct_result_i.uop;
    direct_writeback.result       = direct_result_i.result;
    direct_writeback.next_pc      = direct_result_i.next_pc;
    direct_writeback.csr_wdata    = direct_result_i.csr_wdata;
    direct_writeback.memory_addr  = direct_result_i.memory_addr;
    direct_writeback.memory_wdata = direct_result_i.memory_wdata;
  end

  always_comb begin
    writeback_result_o = direct_writeback;
    writeback_valid_o  = direct_valid_i;

    if (memory_valid_i) begin
      writeback_result_o = memory_result_i;
      writeback_valid_o  = 1'b1;
    end
  end

  assign memory_ready_o = writeback_ready_i;
  assign direct_ready_o = writeback_ready_i && !memory_valid_i;

  // P0 has one instruction in flight, so direct_valid_i and memory_valid_i are
  // mutually exclusive. NOTE(P5): replace this mux with a multi-port completion
  // network when independent execution units can complete concurrently.

endmodule
