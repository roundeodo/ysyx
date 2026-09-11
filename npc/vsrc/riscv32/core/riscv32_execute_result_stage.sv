// EX/MEM流水级寄存器。EXU在前一拍计算真实架构后继PC，本级在寄存边界之后
// 校验前端预测并生成redirect；寄存后的执行结果还旁路到下一条指令的EX输入。
module riscv32_execute_result_stage
  import riscv32_pkg::*;
(
    input logic clk_i,
    input logic rst_ni,

    input  execute_result_t executed_result_i,
    input  logic            executed_result_valid_i,
    output logic            executed_result_ready_o,

    output execute_result_t resolved_result_o,
    output logic            resolved_result_valid_o,
    input  logic            resolved_result_ready_i,

    // 更老的执行级分支恢复或commit级恢复会取消同拍到达的年轻结果。
    // flush只清下一拍valid，不组合修改ready。
    input logic flush_i
);

  execute_result_t execute_result_q;
  logic            execute_result_valid_q;
  logic            execute_result_valid_d;
  logic            stage_can_accept;
  program_counter_t predicted_next_pc_q;
  logic             branch_prediction_mismatch;

  assign stage_can_accept        = !execute_result_valid_q || resolved_result_ready_i;
  // flush只清除valid，ready仍只描述本级容量。年轻普通结果可以在恢复拍物理写入
  // payload寄存器，但其valid在同一时钟沿被清零，因此不会到达completion/commit。
  // 带副作用的LSU请求则在EXU接口处单独禁止。
  assign executed_result_ready_o = stage_can_accept;
  assign resolved_result_valid_o = execute_result_valid_q;

  // 预测顺序后继在寄存器入口计算，避免输出侧再串联 PC+4、选择和地址比较。
  assign branch_prediction_mismatch = execute_result_q.next_pc != predicted_next_pc_q;

  always_comb begin
    resolved_result_o                              = execute_result_q;
    resolved_result_o.redirect_valid               = 1'b0;
    resolved_result_o.redirect_req                 = '0;
    resolved_result_o.redirect_req.target_pc       = execute_result_q.next_pc;
    resolved_result_o.redirect_req.source_pc       = execute_result_q.uop.pc;
    resolved_result_o.redirect_req.reason          = REDIRECT_BRANCH_MISPREDICT;
    resolved_result_o.redirect_req.flush_inclusive = 1'b0;

    if ((execute_result_q.uop.fu_type == FU_BRANCH) &&
        !execute_result_q.uop.exception_valid && branch_prediction_mismatch) begin
      resolved_result_o.redirect_valid = 1'b1;
    end
  end

  always_comb begin
    execute_result_valid_d = execute_result_valid_q;

    if (stage_can_accept) begin
      execute_result_valid_d = executed_result_valid_i;
    end

    if (flush_i) begin
      execute_result_valid_d = 1'b0;
    end
  end

  // payload无需复位；valid=0时其数值没有架构含义。
  always_ff @(posedge clk_i) begin
    if (executed_result_valid_i && executed_result_ready_o) begin
      execute_result_q <= executed_result_i;
      predicted_next_pc_q <= executed_result_i.uop.prediction.predicted_taken ?
                             executed_result_i.uop.prediction.predicted_target :
                             executed_result_i.uop.pc + program_counter_t'(INSTRUCTION_BYTES);
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      execute_result_valid_q <= 1'b0;
    end else begin
      execute_result_valid_q <= execute_result_valid_d;
    end
  end

`ifndef SYNTHESIS
  /* verilator lint_off SYNCASYNCNET */
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (resolved_result_valid_o && !resolved_result_ready_i && !flush_i)
    |=> (resolved_result_valid_o && $stable(resolved_result_o)))
  else $error("EX/MEM stage changed result while backpressured");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    flush_i |=> !resolved_result_valid_o)
  else $error("EX/MEM stage retained a result after pipeline recovery");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (resolved_result_valid_o && resolved_result_o.redirect_valid) |->
      ((resolved_result_o.uop.fu_type == FU_BRANCH) &&
       !resolved_result_o.uop.exception_valid && branch_prediction_mismatch))
  else $error("EX/MEM stage generated a redirect without a valid branch misprediction");
  /* verilator lint_on SYNCASYNCNET */
`endif

endmodule
