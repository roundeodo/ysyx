// EX/MEM解耦队列。EXU在前一拍计算真实架构后继PC，本级在寄存边界之后
// 校验前端预测并生成redirect，从而切断“前递 -> 分支计算 -> 预测比较 -> redirect”的长路径。
//
// 两个入口同时切断EXU ready到completion/WB ready的组合链。队列输出保持严格程序序，
// 因而不会改变现有completion、异常或commit接口的语义。
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

  localparam int unsigned ENTRY_COUNT = 2;

  execute_result_t execute_result_array_q [ENTRY_COUNT];
  execute_result_t head_execute_result;
  logic            read_entry_index_q;
  logic            read_entry_index_d;
  logic            write_entry_index_q;
  logic            write_entry_index_d;
  logic [1:0]      stored_entry_count_q;
  logic [1:0]      stored_entry_count_d;
  logic            input_handshake_occurred;
  logic            output_handshake_occurred;
  program_counter_t sequential_next_pc;
  program_counter_t predicted_next_pc;
  logic             branch_prediction_mismatch;

  // 上游ready只看本级占用数；禁止把resolved_result_ready_i组合传播回EXU。
  assign executed_result_ready_o = (stored_entry_count_q != 2'd2) && !flush_i;
  assign resolved_result_valid_o = stored_entry_count_q != 0;
  assign head_execute_result     = execute_result_array_q[read_entry_index_q];

  assign input_handshake_occurred = executed_result_valid_i && executed_result_ready_o;
  assign output_handshake_occurred = resolved_result_valid_o && resolved_result_ready_i;

  assign sequential_next_pc = head_execute_result.uop.pc +
                              program_counter_t'(INSTRUCTION_BYTES);
  assign predicted_next_pc = head_execute_result.uop.prediction.predicted_taken ?
                             head_execute_result.uop.prediction.predicted_target :
                             sequential_next_pc;
  assign branch_prediction_mismatch = head_execute_result.next_pc != predicted_next_pc;

  // 输出和分支预测校验。只修改redirect字段，其余执行结果逐位保持。
  always_comb begin
    resolved_result_o                              = head_execute_result;
    resolved_result_o.redirect_valid               = 1'b0;
    resolved_result_o.redirect_req                 = '0;
    resolved_result_o.redirect_req.target_pc       = head_execute_result.next_pc;
    resolved_result_o.redirect_req.source_pc       = head_execute_result.uop.pc;
    resolved_result_o.redirect_req.reason          = REDIRECT_BRANCH_MISPREDICT;
    resolved_result_o.redirect_req.flush_inclusive = 1'b0;

    if ((head_execute_result.uop.fu_type == FU_BRANCH) &&
        !head_execute_result.uop.exception_valid && branch_prediction_mismatch) begin
      resolved_result_o.redirect_valid = 1'b1;
    end
  end

  always_comb begin
    read_entry_index_d   = read_entry_index_q;
    write_entry_index_d  = write_entry_index_q;
    stored_entry_count_d = stored_entry_count_q;

    if (input_handshake_occurred) begin
      write_entry_index_d = write_entry_index_q + 1'b1;
    end

    if (output_handshake_occurred) begin
      read_entry_index_d = read_entry_index_q + 1'b1;
    end

    unique case ({input_handshake_occurred, output_handshake_occurred})
      2'b10: stored_entry_count_d = stored_entry_count_q + 1'b1;
      2'b01: stored_entry_count_d = stored_entry_count_q - 1'b1;
      default: ;
    endcase

    if (flush_i) begin
      read_entry_index_d   = 1'b0;
      write_entry_index_d  = 1'b0;
      stored_entry_count_d = '0;
    end
  end

  // payload无需复位；stored_entry_count_q=0时数组内容没有架构语义。
  always_ff @(posedge clk_i) begin
    if (input_handshake_occurred) begin
      execute_result_array_q[write_entry_index_q] <= executed_result_i;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      read_entry_index_q   <= 1'b0;
      write_entry_index_q  <= 1'b0;
      stored_entry_count_q <= '0;
    end else begin
      read_entry_index_q   <= read_entry_index_d;
      write_entry_index_q  <= write_entry_index_d;
      stored_entry_count_q <= stored_entry_count_d;
    end
  end

`ifndef SYNTHESIS
  /* verilator lint_off SYNCASYNCNET */
  assert property (@(posedge clk_i) disable iff (!rst_ni)
    stored_entry_count_q <= 2'd2)
  else $error("EX/MEM queue occupancy exceeded its capacity");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (resolved_result_valid_o && !resolved_result_ready_i && !flush_i)
    |=> (resolved_result_valid_o && $stable(resolved_result_o)))
  else $error("EX/MEM queue changed its head result while backpressured");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    flush_i |=> !resolved_result_valid_o)
  else $error("EX/MEM queue retained a result after commit recovery");

  assert property (@(posedge clk_i) disable iff (!rst_ni)
    (resolved_result_valid_o && resolved_result_o.redirect_valid) |->
      ((resolved_result_o.uop.fu_type == FU_BRANCH) &&
       !resolved_result_o.uop.exception_valid && branch_prediction_mismatch))
  else $error("EX/MEM queue generated a redirect without a valid branch misprediction");
  /* verilator lint_on SYNCASYNCNET */
`endif

endmodule
