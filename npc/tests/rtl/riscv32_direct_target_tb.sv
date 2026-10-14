// Independent immediate/target/direction contract, including wrap and unaligned targets.
module riscv32_direct_target_tb;
  logic [31:0] pc, instruction, target;
  logic [1:0] counter;
  logic known, taken;
  int displacement;
  logic expected_taken;

  riscv32_direct_target dut (
      .pc_i(pc), .instruction_i(instruction), .direction_counter_i(counter),
      .known_o(known), .taken_o(taken), .target_o(target)
  );

  function automatic logic [31:0] encode_branch(input int offset, input int condition);
    logic [12:0] imm;
    imm = 13'(offset);
    return {imm[12], imm[10:5], 5'd7, 5'd3, 3'(condition), imm[4:1], imm[11], 7'b1100011};
  endfunction

  function automatic logic [31:0] encode_jump(input int offset);
    logic [20:0] imm;
    imm = 21'(offset);
    return {imm[20], imm[10:1], imm[11], imm[19:12], 5'd1, 7'b1101111};
  endfunction

  initial begin
    for (int index = 0; index < 8192; index++) begin
      pc = index % 7 == 0 ? 32'hffff_fffc : 32'($urandom);
      counter = 2'(index);
      displacement = (index % 4096 - 2048) * 2;
      instruction = encode_branch(displacement, index % 8);
      expected_taken = counter >= 2;
      case (riscv_config_pkg::BRANCH_STATIC_POLICY)
        1: expected_taken = displacement < 0;
        2: if (counter == 1 || counter == 2) expected_taken = displacement < 0;
        default: ;
      endcase
      #1;
      assert (known == (index % 8 != 2 && index % 8 != 3))
        else $fatal(1, "branch recognition mismatch");
      assert (taken == (known && expected_taken) && target == pc + 32'(displacement))
        else $fatal(1, "branch target/direction mismatch at %0d", index);

      displacement = index % 4 == 0 ? -1048576 :
                     index % 4 == 1 ? 1048574 : ($signed($urandom) % 524288) * 2;
      instruction = encode_jump(displacement);
      #1;
      assert (known && taken && target == pc + 32'(displacement))
        else $fatal(1, "JAL target mismatch at %0d", index);

      instruction = index % 2 == 0 ? 32'h00008067 : 32'h00000013;
      #1;
      assert (!known && !taken) else $fatal(1, "non-direct instruction recognized");
    end
    $display("PASS direct target: 24576 independent B/J/non-direct cases, policy=%0d",
             riscv_config_pkg::BRANCH_STATIC_POLICY);
    $finish;
  end
endmodule
