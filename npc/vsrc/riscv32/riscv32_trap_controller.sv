module riscv32_trap_controller
  import riscv32_pkg::*;
(
    input commit_t commit_i,
    input logic    commit_valid_i,

    input logic [XLEN-1:0] mtvec_i,
    input logic [XLEN-1:0] mepc_i,

    output logic            trap_valid_o,
    output logic [XLEN-1:0] trap_pc_o,
    output logic [XLEN-1:0] trap_cause_o,
    output logic [XLEN-1:0] trap_tval_o,
    output logic            mret_valid_o,

    output redirect_req_t redirect_o,
    output logic          redirect_valid_o
);
  always_comb begin
    trap_valid_o     = commit_valid_i && commit_i.trap_taken;
    trap_pc_o        = commit_i.pc;
    trap_cause_o     = {commit_i.trap_is_interrupt, commit_i.trap_cause_code};
    trap_tval_o      = commit_i.trap_tval;
    mret_valid_o     = commit_valid_i && !commit_i.trap_taken && (commit_i.system_op == SYS_MRET);
    redirect_o       = '0;
    redirect_valid_o = 1'b0;

    if (trap_valid_o) begin
      redirect_valid_o           = 1'b1;
      redirect_o.target_pc       = {mtvec_i[XLEN-1:2], 2'b00};
      redirect_o.source_pc       = commit_i.pc;
      redirect_o.reason          = REDIRECT_TRAP;
      redirect_o.flush_inclusive = 1'b0;
    end else if (mret_valid_o) begin
      redirect_valid_o           = 1'b1;
      redirect_o.target_pc       = mepc_i;
      redirect_o.source_pc       = commit_i.pc;
      redirect_o.reason          = REDIRECT_MRET;
      redirect_o.flush_inclusive = 1'b0;
    end
  end

  // NOTE(P4): interrupt acceptance belongs here at a commit-safe boundary.
  // NOTE(P6): redirect age then comes from the committing ROB entry.

endmodule
