// EX/MEM流水级寄存器。EXU在前一拍计算真实架构后继PC，本级在寄存边界之后
// 校验前端预测并生成redirect，从而切断“前递 -> 分支计算 -> 预测比较 -> redirect”的长路径。
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

    // commit级恢复会取消本级中更年轻的结果。分支自身产生的redirect不能清除自身。
    input logic flush_i
);

  execute_result_t execute_result_q;
  logic            execute_result_valid_q;
  logic            execute_result_valid_d;
  logic            stage_can_accept;
  program_counter_t sequential_next_pc;
  program_counter_t predicted_next_pc;
  logic             branch_prediction_mismatch;

  assign stage_can_accept        = !execute_result_valid_q || resolved_result_ready_i;
  assign executed_result_ready_o = stage_can_accept && !flush_i;
  assign resolved_result_valid_o = execute_result_valid_q;

  assign sequential_next_pc = execute_result_q.uop.pc +
                              program_counter_t'(INSTRUCTION_BYTES);
  assign predicted_next_pc = execute_result_q.uop.prediction.predicted_taken ?
                             execute_result_q.uop.prediction.predicted_target :
                             sequential_next_pc;
  assign branch_prediction_mismatch = execute_result_q.next_pc != predicted_next_pc;

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
  else $error("EX/MEM stage retained a result after commit recovery");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (resolved_result_valid_o && resolved_result_o.redirect_valid) |->
      ((resolved_result_o.uop.fu_type == FU_BRANCH) &&
       !resolved_result_o.uop.exception_valid && branch_prediction_mismatch))
  else $error("EX/MEM stage generated a redirect without a valid branch misprediction");
  /* verilator lint_on SYNCASYNCNET */
`endif

endmodule
