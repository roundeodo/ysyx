module riscv32_reset_controller_tb;
  logic clk = 1'b0;
  logic rst_n = 1'b1;
  logic system_rst_n;
  riscv32_reset_controller u_dut (.clk_i(clk), .rst_ni(rst_n), .rst_no(system_rst_n));

  task automatic check_reset(input logic expected);
    assert (system_rst_n === expected) else $fatal(1, "Unexpected reset release state");
  endtask

  task automatic first_cycle;
    clk = 1'b1; #1; check_reset(1'b0);
    clk = 1'b0; #1; check_reset(1'b0);
  endtask

  initial begin
    for (int unsigned phase_delay = 1; phase_delay <= 4; phase_delay++) begin
      // 停钟时也必须立即复位，释放则必须等待时钟恢复。
      rst_n = 1'b0; #1; check_reset(1'b0);
      clk = 1'b0; #(phase_delay);
      rst_n = 1'b1; #3; check_reset(1'b0);
      first_cycle();
      clk = 1'b1; #1; check_reset(1'b0);
      clk = 1'b0; #1; check_reset(1'b1);
      // 时钟停在高电平时重新复位，并检查同步过程中再次复位会重新计数。
      clk = 1'b1; #1;
      rst_n = 1'b0; #1; check_reset(1'b0);
      rst_n = 1'b1; #3; check_reset(1'b0);
      clk = 1'b0; #1; check_reset(1'b0);
      first_cycle();
      rst_n = 1'b0; #1; check_reset(1'b0);
      rst_n = 1'b1; #1;
      first_cycle();
      clk = 1'b1; #1; check_reset(1'b0);
      clk = 1'b0; #1; check_reset(1'b1);
    end
    $display("PASS reset controller: async assertion, stopped clock, falling-edge release, reassert during synchronization");
    $finish;
  end
endmodule
