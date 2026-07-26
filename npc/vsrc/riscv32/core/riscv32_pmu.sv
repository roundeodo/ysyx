module riscv32_pmu
  import riscv32_pkg::*;
#(
    parameter int unsigned COMMIT_WIDTH = 1
) (
    input logic clk_i,
    input logic rst_ni,

    input logic [$clog2(COMMIT_WIDTH + 1)-1:0] retired_instruction_count_i,

    input  logic [    11:0] csr_read_addr_i,
    output logic            csr_read_select_o,
    output logic [XLEN-1:0] csr_read_data_o,

    input logic            csr_write_valid_i,
    input logic [    11:0] csr_write_addr_i,
    input logic [XLEN-1:0] csr_write_data_i
);
  // PMU owns the counter state. The CSR file only forwards architectural CSR
  // accesses, so adding events later does not expand the CSR file's state logic.

  // TODO(PMU-1): Define the machine counter CSR addresses immediately below.
  // Required first version:
  //   mcycle         12'hB00    minstret         12'hB02
  //   mcycleh        12'hB80    minstreth        12'hB82
  //   mcountinhibit  12'h320
  // Keep these constants in PMU because this module owns their implementation.

  // TODO(PMU-2): Declare the counter and control state immediately below.
  // Use explicit next-state/current-state pairs so update priority remains clear:
  //   logic [63:0] mcycle_d, mcycle_q;
  //   logic [63:0] minstret_d, minstret_q;
  //   logic [31:0] mcountinhibit_d, mcountinhibit_q;
  // mcountinhibit.CY is bit 0 and inhibits mcycle. IR is bit 2 and inhibits
  // minstret. Leave unimplemented bits hardwired to zero when writing the CSR.

  // TODO(PMU-3): Replace this placeholder with the PMU CSR read-output block.
  // Put default assignments first, then decode csr_read_addr_i:
  //   csr_read_select_o = 1'b1 only for a CSR implemented by this PMU;
  //   csr_read_data_o   = the selected 32-bit half on RV32.
  // Reading mcountinhibit returns its implemented bits. An address outside PMU
  // must leave select low so riscv32_csr_file can decode it or report illegal.
  always_comb begin
    csr_read_select_o = 1'b0;
    csr_read_data_o   = '0;
  end

  // TODO(PMU-4): Add the counter next-state block immediately below.
  // Start by holding every _d signal at its _q value. Then apply this priority:
  //   1. A committed CSR write replaces the addressed counter half/control CSR.
  //   2. Otherwise increment mcycle when mcountinhibit_q[0] == 0.
  //   3. Otherwise/independently add retired_instruction_count_i to minstret
  //      when mcountinhibit_q[2] == 0.
  // The two counters increment independently; do not express them as one shared
  // else-if chain. For a low-half write preserve [63:32], and vice versa.
  // For mcountinhibit, retain only implemented bits 0 and 2.

  // TODO(PMU-5): Add the sequential state-update blocks immediately below.
  // Reset all PMU state to zero. Group each closely related register family in
  // a small always_ff block rather than one unrelated monolithic update block.
  // Example grouping: one block for mcycle, one for minstret, one for control.

  // TODO(PMU-6): After the fixed counters work, add assertions here.
  // Check at least:
  //   - retired_instruction_count_i never exceeds COMMIT_WIDTH;
  //   - unimplemented mcountinhibit bits remain zero;
  //   - PMU never drives csr_read_select_o for an unimplemented address.
  // These assertions observe PMU behavior only and must not feed back into the
  // retirement path. That keeps performance monitoring off the CPU critical path.

endmodule
