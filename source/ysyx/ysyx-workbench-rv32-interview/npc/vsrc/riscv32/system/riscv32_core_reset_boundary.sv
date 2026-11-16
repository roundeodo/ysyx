// STA 边界：与实际 system 相同的复位控制器，加纯核；不包含 CLINT 和 SoC。
module riscv32_core_reset_boundary
  import riscv32_pkg::*;
  import riscv32_axi4_pkg::*;
#(
    parameter program_counter_t RESET_PC = RESET_VECTOR
) (
    input  logic                    clk_i,
    input  logic                    rst_ni,
    input  logic                    timer_interrupt_i,
    output axi4_manager_to_target_t instruction_axi4_manager_o,
    input  axi4_target_to_manager_t instruction_axi4_manager_i,
    output axi4_manager_to_target_t data_axi4_manager_o,
    input  axi4_target_to_manager_t data_axi4_manager_i
);
  logic core_rst_n;

  riscv32_reset_controller u_reset_controller (
      .clk_i  (clk_i),
      .rst_ni (rst_ni),
      .rst_no (core_rst_n)
  );

  riscv32_core #(.RESET_PC(RESET_PC)) u_core (
      .clk_i                      (clk_i),
      .rst_ni                     (core_rst_n),
      .timer_interrupt_i          (timer_interrupt_i),
      .instruction_axi4_manager_o (instruction_axi4_manager_o),
      .instruction_axi4_manager_i (instruction_axi4_manager_i),
      .data_axi4_manager_o        (data_axi4_manager_o),
      .data_axi4_manager_i        (data_axi4_manager_i)
  );
endmodule : riscv32_core_reset_boundary
