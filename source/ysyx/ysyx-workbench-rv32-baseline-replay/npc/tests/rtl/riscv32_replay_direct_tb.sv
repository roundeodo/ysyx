// B/J立即数边界、强弱方向选择及目标为PC+4时的真实taken。
module riscv32_replay_direct_tb;
  import riscv32_pkg::*;
  logic [31:0] instruction, target;
  logic [1:0] counter;
  logic known, taken;
  localparam logic [31:0] PC = 32'h80001000;
  riscv32_direct_target target_calc (
      .pc_i(PC), .instruction_i(instruction), .direction_counter_i(counter),
      .known_o(known), .taken_o(taken), .target_o(target)
  );
  execute_packet_t packet;
  execute_result_t result;
  riscv32_exu exu (
      .execute_packet_i(packet), .execute_packet_valid_i(1'b1),
      .execute_packet_issue_allowed_i(1'b1), .execute_packet_ready_o(),
      .exu_result_o(result), .exu_result_valid_o(), .exu_result_ready_i(1'b1),
      .lsu_req_o(), .lsu_req_valid_o(), .lsu_req_ready_i(1'b1),
      .sequential_redirect_o(), .sequential_redirect_valid_o()
  );
  function automatic logic [31:0] branch(input int offset, input logic [2:0] funct3);
    logic [12:0] imm;
    imm=13'(offset);
    return {imm[12],imm[10:5],5'b0,5'b0,funct3,imm[4:1],imm[11],7'b1100011};
  endfunction
  function automatic logic [31:0] jump(input int offset);
    logic [20:0] imm;
    imm=21'(offset);
    return {imm[20],imm[10:1],imm[11],imm[19:12],5'b0,7'b1101111};
  endfunction
  int branch_offsets[5]='{-4096,-4,0,4,4094};
  int jump_offsets[5]='{-1048576,-4,0,4,1048574};
  logic [2:0] branch_kinds[6]='{3'b000,3'b001,3'b100,3'b101,3'b110,3'b111};
  bit expected_taken;
  int checks=0;
  initial begin
    instruction=32'h13; counter=0; packet='0; #1;
    assert(!known && !taken) else $fatal(1,"ordinary integer identified as control flow");
    foreach(branch_offsets[i]) foreach(branch_kinds[j]) begin
      for(int c=0;c<4;c++) begin
        instruction=branch(branch_offsets[i],branch_kinds[j]); counter=2'(c);
        expected_taken=c>=2;
        if(riscv_config_pkg::BRANCH_STATIC_POLICY==1 ||
           (riscv_config_pkg::BRANCH_STATIC_POLICY==2 && c inside {1,2}))
          expected_taken=branch_offsets[i]<0;
        #1;
        assert(known && taken==expected_taken && target==PC+32'(branch_offsets[i]))
          else $fatal(1,"conditional direction/immediate mismatch");
        checks++;
      end
    end
    foreach(jump_offsets[i]) begin
      instruction=jump(jump_offsets[i]); #1;
      assert(known && taken && target==PC+32'(jump_offsets[i]))
        else $fatal(1,"JAL immediate mismatch");
      checks++;
    end
    instruction=32'h00008067; #1;
    assert(!known && !taken) else $fatal(1,"JALR must stay on BTB/RAS/EX path");
    packet='0;
    packet.uop.fu_type=FU_BRANCH; packet.uop.pc=PC; packet.uop.imm=4;
    packet.uop.branch_ctrl.op=CF_BRANCH; packet.uop.branch_ctrl.condition=BR_BEQ;
    packet.source_a_value=17; packet.source_b_value=17; #1;
    assert(result.branch_taken && result.next_pc==PC+4)
      else $fatal(1,"taken branch to PC+4 lost its direction");
    packet.source_b_value=18; #1;
    assert(!result.branch_taken && result.next_pc==PC+4)
      else $fatal(1,"not-taken branch to PC+4 wrong direction");
    $display("PASS replay direct targets: %0d direction/immediate checks, taken/not-taken PC+4",checks);
    $finish;
  end
endmodule
