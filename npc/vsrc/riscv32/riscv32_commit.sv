module riscv32_commit
  import riscv32_pkg::*;
(
    input  writeback_result_t writeback_result_i,
    input  logic              writeback_result_valid_i,
    output logic              writeback_result_ready_o,

    output commit_t commit_o,
    output logic    commit_valid_o,

    output logic          [XLEN-1:0] gpr_write_data_o,
    output arch_reg_idx_t            gpr_write_addr_o,
    output logic                     gpr_write_enable_o
);
  assign writeback_result_ready_o = 1'b1;
  assign commit_valid_o           = writeback_result_valid_i && writeback_result_ready_o;

  always_comb begin
    commit_o                   = '0;
    commit_o.pc                = writeback_result_i.uop.pc;
    commit_o.instruction       = writeback_result_i.uop.instruction;
    commit_o.next_pc           = writeback_result_i.next_pc;
    commit_o.gpr_write         = writeback_result_i.uop.writes_rd &&
                                 !writeback_result_i.uop.exception_valid;
    commit_o.gpr_addr          = writeback_result_i.uop.rd;
    commit_o.gpr_wdata         = writeback_result_i.result;
    commit_o.csr_write         = writeback_result_i.uop.csr_ctrl.write_enable &&
                                 !writeback_result_i.uop.exception_valid;
    commit_o.csr_addr          = writeback_result_i.uop.csr_ctrl.addr;
    commit_o.csr_wdata         = writeback_result_i.csr_wdata;
    commit_o.memory_access     = (writeback_result_i.uop.mem_ctrl.cmd != MEM_CMD_NONE) &&
                                 !writeback_result_i.uop.exception_valid;
    commit_o.memory_cmd        = writeback_result_i.uop.mem_ctrl.cmd;
    commit_o.memory_size       = writeback_result_i.uop.mem_ctrl.size;
    commit_o.memory_addr       = writeback_result_i.memory_addr;
    commit_o.memory_rdata      = writeback_result_i.memory_rdata;
    commit_o.memory_wdata      = writeback_result_i.memory_wdata;
    commit_o.memory_wmask      = writeback_result_i.memory_wmask;
    commit_o.trap_taken        = writeback_result_i.uop.exception_valid;
    commit_o.trap_is_interrupt = 1'b0;
    commit_o.trap_cause_code   = {{(XLEN - 6) {1'b0}}, writeback_result_i.uop.exception_cause};
    commit_o.trap_tval         = writeback_result_i.uop.exception_tval;
    commit_o.privilege         = PRIV_MODE_M;
    commit_o.system_op         = writeback_result_i.uop.system_op;
  end

  assign gpr_write_data_o   = commit_o.gpr_wdata;
  assign gpr_write_addr_o   = commit_o.gpr_addr;
  assign gpr_write_enable_o = commit_valid_o && commit_o.gpr_write && (commit_o.gpr_addr != '0);

  // This width-1 boundary is the architectural side-effect authority in P0.
  // NOTE(P6): a ROB will later choose the oldest completed entries and drive
  // the same commit_t contract in program order.

endmodule
