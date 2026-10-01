// 历史正确性独立于next-PC正确性；覆盖分支漏插入、方向错误和类型误识别。
module history_repair_tb;
  import riscv32_pkg::*;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  execute_result_t incoming, resolved;
  logic incoming_valid = 0, resolved_valid;
  execute_packet_t packet;
  logic issue_allowed = 1, consumer_ready = 1, sequential_redirect;
  riscv32_ex_result_reg result_reg (
      .clk_i(clk),.rst_ni(rst_n),.executed_result_i(incoming),
      .executed_result_valid_i(incoming_valid),.executed_result_ready_o(),
      .resolved_result_o(resolved),.resolved_result_valid_o(resolved_valid),
      .resolved_result_ready_i(1'b1),.flush_i(1'b0));
  riscv32_exu exu (
      .execute_packet_i(packet),.execute_packet_valid_i(1'b1),
      .execute_packet_issue_allowed_i(issue_allowed),.execute_packet_ready_o(),
      .exu_result_o(),.exu_result_valid_o(),.exu_result_ready_i(consumer_ready),
      .lsu_req_o(),.lsu_req_valid_o(),.lsu_req_ready_i(consumer_ready),
      .sequential_redirect_o(),.sequential_redirect_valid_o(sequential_redirect));
  task automatic check_branch(input control_flow_op_e operation, input bit inserted, chosen, actual, exception, expected);
    @(negedge clk);
    incoming = '0;
    incoming.uop.pc = 32'h80000100;
    incoming.uop.fu_type = FU_BRANCH;
    incoming.uop.branch_ctrl.op = operation;
    incoming.uop.exception_valid = exception;
    incoming.uop.prediction.direction.history_inserted = inserted;
    incoming.uop.prediction.direction.history_taken = chosen;
    incoming.branch_taken = actual;
    incoming.next_pc = 32'h80000104;
    incoming_valid = 1;
    @(posedge clk);#1;
    assert(resolved_valid && resolved.redirect_valid == expected)
      else $fatal(1,"history repair op=%0d inserted=%b chosen=%b actual=%b exception=%b",operation,inserted,chosen,actual,exception);
    assert(resolved.redirect_req.target_pc == incoming.next_pc) else $fatal;
  endtask
  initial begin
    incoming = '0;packet = '0;
    repeat(2) @(negedge clk);rst_n = 1;
    check_branch(CF_BRANCH,0,0,0,0,1); // 漏识别且NT，PC没有错误。
    check_branch(CF_BRANCH,1,0,1,0,1); // taken目标恰好PC+4。
    check_branch(CF_BRANCH,1,1,1,0,0);
    check_branch(CF_JAL,1,0,1,0,1); // 实际无条件跳转，删除多插方向位。
    check_branch(CF_JALR,1,0,1,0,1);
    check_branch(CF_JAL,0,0,1,0,0);
    check_branch(CF_BRANCH,0,0,0,1,0); // 异常优先，不产生预测恢复。
    for (int memory_operation=0; memory_operation<2; memory_operation++) begin
      packet = '0;
      packet.uop.fu_type = memory_operation ? FU_LSU : FU_INT;
      packet.uop.prediction.direction.history_inserted = 1;
      #1;assert(sequential_redirect) else $fatal(1,"nonbranch false conditional not repaired");
      consumer_ready = 0;
      #1;assert(!sequential_redirect) else $fatal(1,"repaired before delivery");
      consumer_ready = 1;issue_allowed = 0;
      #1;assert(!sequential_redirect) else $fatal(1,"ignored older recovery");
      issue_allowed = 1;packet.uop.exception_valid = 1;
      #1;assert(!sequential_redirect) else $fatal(1,"ignored exception");
    end
    $display("PASS history repair: missing, wrong direction, wrong type, LSU, stalls, exception");
    $finish;
  end
endmodule
