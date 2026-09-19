module riscv32_interrupt_control_tb;
  import riscv32_pkg::*;
  logic clk = 0;
  logic rst_n = 0;
  always #5 clk = ~clk;
  logic enabled = 0;
  logic backend_busy = 0;
  logic maintenance_busy = 0;
  logic commit_valid = 0;
  commit_t commit;
  logic redirect_valid = 0;
  redirect_req_t redirect;
  logic issue_hold;
  logic interrupt_valid;
  logic [31:0] interrupt_pc;

  riscv32_interrupt_ctrl #(
      .RESET_PC(32'h8000_0000)
  ) dut (
      .clk_i                    (clk),
      .rst_ni                   (rst_n),
      .timer_interrupt_enabled_i(enabled),
      .backend_busy_i           (backend_busy),
      .maintenance_busy_i       (maintenance_busy),
      .commit_valid_i           (commit_valid),
      .commit_i                 (commit),
      .redirect_valid_i         (redirect_valid),
      .redirect_i               (redirect),
      .issue_hold_o             (issue_hold),
      .interrupt_valid_o        (interrupt_valid),
      .interrupt_pc_o           (interrupt_pc)
  );

  initial begin
    commit   = '0;
    redirect = '0;
    repeat (3) @(negedge clk);
    rst_n   = 1;
    // 前端没有指令、没有 commit 时仍能响应中断。
    enabled = 1;
    #1;
    assert (issue_hold && interrupt_valid && interrupt_pc == 32'h8000_0000)
    else $fatal(1, "idle core cannot accept an interrupt");
    backend_busy = 1;
    #1;
    assert (issue_hold && !interrupt_valid)
    else $fatal(1, "LSU was not drained");
    enabled = 0;
    #1;
    assert (!issue_hold && !interrupt_valid)
    else $fatal(1, "withdrawn interrupt remained latched");
    @(negedge clk);
    backend_busy     = 0;
    enabled          = 1;
    maintenance_busy = 1;
    #1;
    assert (issue_hold && !interrupt_valid)
    else $fatal(1, "maintenance was interrupted");
    @(negedge clk);
    enabled          = 0;
    maintenance_busy = 0;
    commit_valid     = 1;
    commit.pc        = 32'h8000_0000;
    commit.next_pc   = 32'h8000_0140;  // 已执行分支的真实目标，不能退化成 pc+4。
    enabled = 1;
    #1;
    assert (!interrupt_valid) else $fatal(1, "interrupt collided with commit");
    @(negedge clk);
    commit_valid = 0;
    enabled      = 1;
    #1;
    assert (interrupt_valid && interrupt_pc == 32'h8000_0140)
    else $fatal(1, "branch resume PC was lost");
    enabled            = 0;
    commit_valid       = 1;
    commit.next_pc     = 32'h8000_0144;
    redirect_valid     = 1;
    redirect.target_pc = 32'h8000_0800;  // trap/mret 重定向优先于普通 next_pc。
    @(negedge clk);
    commit_valid   = 0;
    redirect_valid = 0;
    enabled        = 1;
    #1;
    assert (interrupt_valid && interrupt_pc == 32'h8000_0800)
    else $fatal(1, "architectural redirect lost priority");
    $display(
        "PASS interrupt control: idle entry, LSU drain, withdrawal, maintenance, branch PC, trap/mret redirect priority");
    $finish;
  end
endmodule
