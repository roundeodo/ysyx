module choice_tb;
  logic [31:0] pc, target;
  logic valid_metadata;
  wire [12:0] displacement = target[12:0]-pc[12:0];
  logic [1:0] counter;
  wire [2:0] taken;
  for (genvar p = 0; p < 3; p++) begin : g_policy
    riscv32_branch_choice #(.POLICY(p)) dut (
        .backward_i(displacement[12]), .metadata_valid_i(valid_metadata),
        .dynamic_counter_i(counter), .taken_o(taken[p]));
  end
  initial begin
    for (int wrap = 0; wrap < 2; wrap++)
      for (int backward = 0; backward < 2; backward++)
        for (int available = 0; available < 2; available++)
          for (int c = 0; c < 4; c++) begin
            pc = wrap ? 32'hfffffffc : 32'h80000000;
            target = backward ? pc-4 : pc+4;
            valid_metadata = 1'(available); counter = 2'(c);
            #1;
            assert(taken[0] == (c>=2)) else $fatal(1,"dynamic selection");
            assert(taken[1] == (available ? backward : c>=2)) else $fatal(1,"static metadata gate");
            assert(taken[2] == (available && (c==1 || c==2) ? backward : c>=2)) else $fatal(1,"weak fallback");
          end
    $display("PASS static/dynamic choice: 32 input cases, 3 policies, wraparound");
    $finish;
  end
endmodule
