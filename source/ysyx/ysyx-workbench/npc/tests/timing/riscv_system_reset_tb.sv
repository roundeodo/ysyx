module riscv_system_reset_tb;
  import riscv_pkg::*;
  import riscv_axi4_pkg::*;

  logic clk = 1'b0;
  logic rst_n = 1'b1;
  logic system_rst_n;
  axi4_manager_to_target_t request;
  axi4_target_to_manager_t response = '0;

  riscv_npc_system #(.RESET_PC(program_counter_t'(32'h8000_0000))) u_dut (
      .clk_i                   (clk),
      .rst_ni                  (rst_n),
      .system_rst_no           (system_rst_n),
      .external_axi4_manager_o (request),
      .external_axi4_manager_i (response)
  );

  task automatic check_quiet;
    assert (!system_rst_n && !request.ar_valid && !request.aw_valid && !request.w_valid)
      else $fatal(1, "System issued AXI traffic before qualified reset release");
    assert (!u_dut.u_core.commit_valid)
      else $fatal(1, "System committed before qualified reset release");
  endtask

  task automatic cycle;
    clk = 1'b1;
    #1;
    clk = 1'b0;
    #1;
  endtask

  initial begin
    for (int unsigned phase_delay = 1; phase_delay <= 8; phase_delay++) begin
      // Reassert while a previous fetch is stalled, including a stopped high clock.
      clk = phase_delay[0];
      rst_n = 1'b0;
      #1;
      check_quiet();
      clk = 1'b0;
      #(phase_delay);
      rst_n = 1'b1;
      #2;
      check_quiet();
      cycle();
      check_quiet();
      clk = 1'b1;
      #1;
      check_quiet();
      clk = 1'b0;
      #1;
      assert (system_rst_n) else $fatal(1, "System reset did not release on falling edge");

      for (int unsigned index = 0; index < 20; index++)
        cycle();
      assert (request.ar_valid && request.ar.addr == 32'h8000_0000)
        else $fatal(1, "Fetch did not restart at the reset vector");
      for (int unsigned index = 0; index < 4; index++) begin
        cycle();
        assert (request.ar_valid && request.ar.addr == 32'h8000_0000)
          else $fatal(1, "Stalled initial fetch changed");
      end
    end
    $display("PASS system reset: eight release phases, no early traffic, stalled fetch cancellation and restart");
    $finish;
  end
endmodule
