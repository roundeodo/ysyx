// 只协调中断接收和恢复 PC；CSR 的所有状态仍由 csr_file 保存。
module riscv32_interrupt_ctrl
  import riscv32_pkg::*;
#(
    parameter program_counter_t RESET_PC = RESET_VECTOR
) (
    input  logic             clk_i,
    input  logic             rst_ni,
    input  logic             timer_interrupt_enabled_i,
    input  logic             backend_busy_i,
    input  logic             maintenance_busy_i,
    input  logic             commit_valid_i,
    input  commit_t          commit_i,
    input  logic             redirect_valid_i,
    input  redirect_req_t    redirect_i,
    output logic             issue_hold_o,
    output logic             interrupt_valid_o,
    output program_counter_t interrupt_pc_o
);
  program_counter_t resume_pc_q;

  // 只阻止新指令进入执行部分，已经发出的 LSU 事务继续完成。
  // 条件直接来自 CSR 和硬件电平，屏蔽或撤销请求后不会接收过期中断。
  assign issue_hold_o      = timer_interrupt_enabled_i;
  assign interrupt_valid_o = timer_interrupt_enabled_i && !backend_busy_i &&
      !maintenance_busy_i && !commit_valid_i;
  assign interrupt_pc_o = resume_pc_q;

  // backend_busy 必须包含执行、结果寄存级、LSU 和写回级的有效状态。
  // redirect 输入只接提交点的架构重定向，不接执行级推测纠错。
  // 独立保存架构 PC，使取指 miss 或前端为空时也能响应中断。
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      resume_pc_q <= RESET_PC;
    end else if (redirect_valid_i) begin
      resume_pc_q <= redirect_i.target_pc;
    end else if (commit_valid_i && !commit_i.trap_taken) begin
      resume_pc_q <= commit_i.next_pc;
    end
  end
endmodule
