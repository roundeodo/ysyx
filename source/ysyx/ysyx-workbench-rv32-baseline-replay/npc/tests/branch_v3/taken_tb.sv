module taken_tb;
  import riscv32_pkg::*;
  execute_packet_t packet;
  execute_result_t result;
  logic ready, result_valid;
  riscv32_exu dut (
      .execute_packet_i(packet), .execute_packet_valid_i(1'b1),
      .execute_packet_issue_allowed_i(1'b1), .execute_packet_ready_o(ready),
      .exu_result_o(result), .exu_result_valid_o(result_valid), .exu_result_ready_i(1'b1),
      .lsu_req_o(), .lsu_req_valid_o(), .lsu_req_ready_i(1'b1),
      .sequential_redirect_o(), .sequential_redirect_valid_o());
  initial begin
    packet = '0;
    packet.uop.fu_type = FU_BRANCH;
    packet.uop.branch_ctrl.op = CF_BRANCH;
    packet.uop.branch_ctrl.condition = BR_BEQ;
    packet.uop.pc = 32'h80000000;
    packet.uop.imm = 4;
    packet.source_a_value = 7;
    for (int taken = 0; taken < 2; taken++) begin
      packet.source_b_value = taken ? 7 : 8;
      #1;
      assert(ready && result_valid && result.next_pc == 32'h80000004) else $fatal(1,"next PC");
      assert(result.branch_taken == 1'(taken)) else $fatal(1,"lost actual branch direction");
    end
    $display("PASS branch target=PC+4 keeps both actual taken outcomes");
    $finish;
  end
endmodule
