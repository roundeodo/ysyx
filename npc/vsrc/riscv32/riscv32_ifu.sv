module riscv32_ifu
  import riscv32_pkg::*;
#(
    parameter logic [XLEN-1:0] PC_START = RESET_VECTOR
) (
    input logic clk_i,
    input logic rst_ni,

    /* verilator lint_off UNUSEDSIGNAL */
    input redirect_req_t redirect_i,
    /* verilator lint_on UNUSEDSIGNAL */
    input logic          redirect_valid_i,

    output fetch_entry_t fetch_entry_o,
    output logic         fetch_valid_o,
    input  logic         fetch_ready_i
);
  // P0 keeps instruction memory combinational. NOTE(P1): move this DPI call to
  // riscv32_sim_mem and replace it with an explicit imem request/response port.
  import "DPI-C" function int pmem_read(input int raddr);

  logic [XLEN-1:0] pc_q;
  logic [XLEN-1:0] pc_d;
  logic            fetch_fire;

  assign fetch_valid_o = rst_ni;
  assign fetch_fire    = fetch_valid_o && fetch_ready_i;

  always_comb begin
    pc_d = pc_q;
    if (redirect_valid_i) begin
      pc_d = redirect_i.target_pc;
    end else if (fetch_fire) begin
      pc_d = pc_q + 32'd4;
    end
  end

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      pc_q <= PC_START;
    end else begin
      pc_q <= pc_d;
    end
  end

  always_comb begin
    fetch_entry_o             = '0;
    fetch_entry_o.pc          = pc_q;
    fetch_entry_o.instruction = pmem_read(pc_q);
  end

  // NOTE(P5): branch prediction, I-cache response tracking, and a fetch queue
  // extend this boundary; redirect remains the only external PC-recovery input.

endmodule
