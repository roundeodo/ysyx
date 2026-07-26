module riscv32_pmu
  import riscv32_pkg::*;
#(
    parameter int unsigned RETIRE_SLOT_COUNT = 1
) (
    input logic clk_i,
    input logic rst_ni,

    input logic [$clog2(RETIRE_SLOT_COUNT + 1)-1:0] retired_instruction_count_i,

    input  logic [    11:0] csr_read_addr_i,
    output logic            csr_read_select_o,
    output logic [XLEN-1:0] csr_read_data_o,

    input logic            csr_write_valid_i,
    input logic [    11:0] csr_write_addr_i,
    input logic [XLEN-1:0] csr_write_data_i
);
  // PMU (Performance Monitoring Unit) passively observes architectural or
  // microarchitectural events and accumulates how many times they occur. It must
  // never generate ready, stall, redirect, or other pipeline-control feedback.
  // Consequently, adding/removing a counter changes observations, not CPU behavior.
  //
  // Current observation path:
  //   core commit boundary
  //     -> count non-trapping instructions retired in this cycle
  //     -> retired_instruction_count_i
  //     -> minstret next-state addition
  //     -> software reads minstret/minstreth through the CSR file
  //
  // mcycle is different: its event source is this module's own active clock. It
  // increments once on each rising edge unless software inhibits it. Future cache
  // miss, branch-mispredict, or stall events should enter through explicit event
  // inputs and follow the same passive accumulation rule.

  // These addresses are the architectural names used by CSR instructions. PMU
  // owns their storage while riscv32_csr_file remains the common CSR access point.
  localparam logic [11:0] CSR_MCYCLE        = 12'hB00;
  localparam logic [11:0] CSR_MINSTRET      = 12'hB02;
  localparam logic [11:0] CSR_MCOUNTINHIBIT = 12'h320;
  localparam logic [11:0] CSR_MCYCLEH       = 12'hB80;
  localparam logic [11:0] CSR_MINSTRETH     = 12'hB82;

  // mcycle counts active core clock cycles. Software combines mcycleh and mcycle
  // into one 64-bit value on RV32. It is the denominator of IPC.
  logic [63:0] mcycle_d;
  logic [63:0] mcycle_q;

  // minstret counts instructions that completed without taking a synchronous
  // exception. It is the numerator of IPC. Adding a count instead of a Boolean
  // makes the same state work when several instructions retire in one cycle.
  logic [63:0] minstret_d;
  logic [63:0] minstret_q;

  // mcountinhibit lets software stop selected counters. Only CY (bit 0) and IR
  // (bit 2) are implemented now. Other bits must always read as zero.
  logic [31:0] mcountinhibit_d;
  logic [31:0] mcountinhibit_q;

  // TODO(PMU-3): Complete this PMU CSR read-output block.
  // csr_read_select_o means "this address belongs to PMU". It is not a read
  // handshake and does not mean that the counter changed. riscv32_csr_file uses
  // it to choose PMU data instead of reporting an illegal CSR address.
  //
  // Write a unique case below the defaults. Each implemented case must assign
  // both select=1 and the corresponding data:
  //
  //   unique case (csr_read_addr_i)
  //     CSR_MCYCLE: begin
  //       csr_read_select_o = 1'b1;
  //       csr_read_data_o   = mcycle_q[31:0];
  //     end
  //     // CSR_MCYCLEH   returns mcycle_q[63:32]
  //     // CSR_MINSTRET  returns minstret_q[31:0]
  //     // CSR_MINSTRETH returns minstret_q[63:32]
  //     // CSR_MCOUNTINHIBIT returns mcountinhibit_q
  //     default: ;
  //   endcase
  //
  // Keep select low for every address not owned by PMU.
  always_comb begin
    csr_read_select_o = 1'b0;
    csr_read_data_o   = '0;
  end

  // TODO(PMU-4): Add one counter next-state block immediately below.
  // This block decides the values captured on the next rising edge. Begin with:
  //
  //   always_comb begin
  //     mcycle_d        = mcycle_q;
  //     minstret_d      = minstret_q;
  //     mcountinhibit_d = mcountinhibit_q;
  //
  // Then implement each state family independently.
  //
  // mcycle update:
  //   if writing CSR_MCYCLE, replace only [31:0];
  //   else if writing CSR_MCYCLEH, replace only [63:32];
  //   else if !mcountinhibit_q[0], use mcycle_q + 64'd1.
  // A CSR write has priority because software expects the written value to be the
  // new counter state, not the written value plus an implicit increment.
  //
  // minstret update uses a separate if/else-if chain:
  //   CSR_MINSTRET/MINSTRETH writes replace the selected half;
  //   otherwise, when !mcountinhibit_q[2], use
  //     minstret_q + {{padding{1'b0}}, retired_instruction_count_i};
  // You may simply rely on unsigned width extension when adding the input, but
  // explicit extension makes the intended 64-bit arithmetic easier to review.
  // A trap contributes zero because core already excludes trap-taking commits.
  //
  // mcountinhibit update:
  //   when writing CSR_MCOUNTINHIBIT, assign
  //     csr_write_data_i & 32'h0000_0005
  // so only CY and IR can become one. Close the always_comb after all three parts.

  // TODO(PMU-5): Add three sequential state-update blocks immediately below.
  // These blocks contain no policy; they only capture the _d values chosen above.
  // Keep the register families separate so each state is adjacent to its purpose:
  //
  //   always_ff @(posedge clk_i or negedge rst_ni) begin
  //     if (!rst_ni) mcycle_q <= '0;
  //     else         mcycle_q <= mcycle_d;
  //   end
  //
  // Repeat the same structure for minstret_q and mcountinhibit_q. Resetting all
  // counters to zero gives deterministic software-visible behavior after reset.

  // TODO(PMU-6): After the fixed counters work, add assertions here.
  // Check at least:
  //   - retired_instruction_count_i never exceeds RETIRE_SLOT_COUNT;
  //   - unimplemented mcountinhibit bits remain zero;
  //   - PMU never drives csr_read_select_o for an unimplemented address.
  // These assertions observe PMU behavior only and must not feed back into the
  // retirement path. The same rule applies to every future performance event:
  // producer -> one-way event signal -> PMU. PMU must never control the producer.

endmodule
