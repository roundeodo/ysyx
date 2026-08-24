// 低面积译码级静态控制流预测器。
//
// 该模块不保存预测表，也不参与valid/ready反压。它观察一条已被ID/EX接收的uop：
// - 后向条件分支按taken预测（BTFNT）；
// - 前向条件分支按not-taken预测；
// - JAL方向和PC相对目标均已知，按taken预测；
// - JALR目标依赖寄存器值，没有BTB/RAS时继续按not-taken预测。
//
// redirect只发送给前端，不能冲掉正在进入ID/EX的分支自身。EX级仍计算真实条件和目标，
// 并在真实next PC与prediction不一致时发出优先级更高的mispredict redirect。
module riscv32_decode_control_flow_predictor
  import riscv32_pkg::*;
(
    input decoded_uop_t decoded_uop_i,
    input logic         decoded_uop_handshake_occurred_i,

    output branch_prediction_t prediction_o,
    output redirect_req_t      predicted_redirect_req_o,
    output logic               predicted_redirect_req_valid_o
);
  program_counter_t sequential_next_pc;
  program_counter_t direct_target_pc;
  logic             direct_target_aligned;
  logic             static_prediction_taken;

  assign sequential_next_pc   = decoded_uop_i.pc + program_counter_t'(INSTRUCTION_BYTES);
  assign direct_target_pc     = decoded_uop_i.pc + decoded_uop_i.imm;
  assign direct_target_aligned = direct_target_pc[1:0] == 2'b00;

  always_comb begin
    static_prediction_taken = 1'b0;

    if (!decoded_uop_i.exception_valid &&
        (decoded_uop_i.fu_type == FU_BRANCH) && direct_target_aligned) begin
      unique case (decoded_uop_i.branch_ctrl.op)
        CF_BRANCH: static_prediction_taken = decoded_uop_i.imm[XLEN-1];
        CF_JAL:    static_prediction_taken = 1'b1;
        default:   static_prediction_taken = 1'b0;
      endcase
    end
  end

  always_comb begin
    prediction_o                 = '0;
    prediction_o.predicted_taken = static_prediction_taken;
    prediction_o.predicted_target = static_prediction_taken ?
                                      direct_target_pc : sequential_next_pc;

    predicted_redirect_req_o                 = '0;
    predicted_redirect_req_o.target_pc       = direct_target_pc;
    predicted_redirect_req_o.source_pc       = decoded_uop_i.pc;
    predicted_redirect_req_o.reason          = REDIRECT_BRANCH_PREDICTION;
    predicted_redirect_req_o.flush_inclusive = 1'b0;

    // 必须以ID/EX握手作为预测生效点。只看valid会在后端反压期间对同一条分支重复redirect。
    predicted_redirect_req_valid_o = decoded_uop_handshake_occurred_i &&
                                     static_prediction_taken;
  end

`ifndef SYNTHESIS
  assert property (@(*) predicted_redirect_req_valid_o |-> prediction_o.predicted_taken)
  else $error("decode predictor redirected without a taken prediction");

  assert property (@(*) prediction_o.predicted_taken |->
                    (prediction_o.predicted_target[1:0] == 2'b00))
  else $error("decode predictor produced a misaligned target");
`endif

endmodule
