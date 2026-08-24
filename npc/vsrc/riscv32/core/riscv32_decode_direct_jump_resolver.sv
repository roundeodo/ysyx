// 译码级JAL目标解析。
//
// JAL的跳转方向和PC相对目标在译码完成后已经确定，因此无需等到
// EX级再恢复前端。本模块不保存BHT/BTB，也不预测条件分支或JALR。
// redirect以ID/EX握手作为唯一生效点，避免后端反压时重复发送同一跳转。
module riscv32_decode_direct_jump_resolver
  import riscv32_pkg::*;
(
    input decoded_uop_t decoded_uop_i,
    input logic         decoded_uop_handshake_occurred_i,

    output branch_prediction_t direct_jump_prediction_o,
    output redirect_req_t      direct_jump_redirect_req_o,
    output logic               direct_jump_redirect_req_valid_o
);
  program_counter_t sequential_next_pc;
  program_counter_t direct_jump_target_pc;
  logic             direct_jump_target_aligned;
  logic             direct_jump_present;

  assign sequential_next_pc        = decoded_uop_i.pc + program_counter_t'(INSTRUCTION_BYTES);
  assign direct_jump_target_pc     = decoded_uop_i.pc + decoded_uop_i.imm;
  assign direct_jump_target_aligned = direct_jump_target_pc[1:0] == 2'b00;
  assign direct_jump_present       = !decoded_uop_i.exception_valid &&
                                     (decoded_uop_i.fu_type == FU_BRANCH) &&
                                     (decoded_uop_i.branch_ctrl.op == CF_JAL) &&
                                     direct_jump_target_aligned;

  always_comb begin
    direct_jump_prediction_o                  = '0;
    direct_jump_prediction_o.predicted_taken  = direct_jump_present;
    direct_jump_prediction_o.predicted_target = direct_jump_present ?
                                                       direct_jump_target_pc : sequential_next_pc;

    direct_jump_redirect_req_o                 = '0;
    direct_jump_redirect_req_o.target_pc       = direct_jump_target_pc;
    direct_jump_redirect_req_o.source_pc       = decoded_uop_i.pc;
    direct_jump_redirect_req_o.reason          = REDIRECT_DECODE_DIRECT_JUMP;
    direct_jump_redirect_req_o.flush_inclusive = 1'b0;

    direct_jump_redirect_req_valid_o = decoded_uop_handshake_occurred_i &&
                                       direct_jump_present;
  end

`ifndef SYNTHESIS
  always_comb begin : check_direct_jump_resolution
    if (direct_jump_redirect_req_valid_o) begin
      assert (direct_jump_prediction_o.predicted_taken)
      else $error("decode direct-jump redirect lacked matching prediction metadata");
      assert (direct_jump_prediction_o.predicted_target[1:0] == 2'b00)
      else $error("decode direct-jump resolver produced a misaligned target");
    end
  end
`endif

endmodule
