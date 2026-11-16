module riscv32_trap_ctrl
  import riscv32_pkg::*;
(
    /* verilator lint_off UNUSEDSIGNAL */
    input  commit_t commit_i,
    input  logic    commit_valid_i,

    // Trap控制器只处理提交点的架构PC和异常元数据，不处理物理总线地址。
    input  program_counter_t mtvec_i,
    /* verilator lint_on UNUSEDSIGNAL */
    input  program_counter_t mepc_i,
    input  logic             interrupt_valid_i,
    input  program_counter_t interrupt_pc_i,

    output logic             trap_valid_o,
    output program_counter_t trap_pc_o,
    output xlen_data_t       trap_cause_o,
    output xlen_data_t       trap_tval_o,
    output logic             mret_valid_o,

    output redirect_req_t redirect_req_o,
    output logic          redirect_req_valid_o
);
  always_comb begin
    trap_valid_o = commit_valid_i && commit_i.trap_taken;
    trap_pc_o    = commit_i.pc;
    // mcause最高位固定表示中断，低位保存cause code；先清零可避免字段宽度隐式耦合。
    trap_cause_o           = '0;
    trap_cause_o[XLEN-1]   = commit_i.trap_is_interrupt;
    trap_cause_o[XLEN-2:0] = commit_i.trap_cause_code;
    trap_tval_o            = commit_i.trap_tval;
    mret_valid_o           = commit_valid_i && !commit_i.trap_taken && (commit_i.system_op == SYS_MRET);
    redirect_req_o         = '0;
    redirect_req_valid_o   = 1'b0;

    if (trap_valid_o) begin
      redirect_req_valid_o = 1'b1;
      // mtvec低两位是模式/对齐字段，不属于跳转地址。
      redirect_req_o.target_pc       = mtvec_i;
      redirect_req_o.target_pc[1:0]  = 2'b00;
      redirect_req_o.source_pc       = commit_i.pc;
      redirect_req_o.reason          = REDIRECT_TRAP;
      redirect_req_o.flush_inclusive = 1'b0;
    end else if (mret_valid_o) begin
      redirect_req_valid_o           = 1'b1;
      redirect_req_o.target_pc       = mepc_i;
      redirect_req_o.source_pc       = commit_i.pc;
      redirect_req_o.reason          = REDIRECT_MRET;
      redirect_req_o.flush_inclusive = 1'b0;
    end else if (interrupt_valid_i) begin
      trap_valid_o                   = 1'b1;
      trap_pc_o                      = interrupt_pc_i;
      trap_cause_o                   = xlen_data_t'(IRQ_MACHINE_TIMER);
      trap_cause_o[XLEN-1]           = 1'b1;
      trap_tval_o                    = '0;
      redirect_req_valid_o           = 1'b1;
      redirect_req_o.target_pc       = {mtvec_i[XLEN-1:2], 2'b00};
      redirect_req_o.source_pc       = interrupt_pc_i;
      redirect_req_o.reason          = REDIRECT_TRAP;
      redirect_req_o.flush_inclusive = 1'b1;
    end
  end

  // 中断是独立架构事件，不伪造 commit，也不增加退休计数。

endmodule
