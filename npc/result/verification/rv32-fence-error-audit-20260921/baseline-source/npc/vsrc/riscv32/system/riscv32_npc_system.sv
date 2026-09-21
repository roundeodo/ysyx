// NPC system boundary: merge the instruction/data managers, terminate the
// core-local CLINT window, and forward all other addresses to the SoC fabric.
module riscv32_npc_system
  import riscv32_pkg::*;
  import riscv32_axi4_pkg::*;
  import riscv32_addr_map_pkg::*;
#(
    parameter logic [XLEN-1:0] RESET_PC = RESET_VECTOR,
`ifdef YSYX_SIM_CPU_FREQ_MHZ
    parameter int unsigned CLINT_CLOCK_FREQ_HZ = `YSYX_SIM_CPU_FREQ_MHZ * 1_000_000,
`else
    parameter int unsigned CLINT_CLOCK_FREQ_HZ = 100_000_000,
`endif
    parameter int unsigned MTIME_INCREMENT_FREQ_HZ = 1_000_000
) (
    input  logic clk_i,
    input  logic rst_ni,
    output logic system_rst_no,

    output axi4_manager_to_target_t external_axi4_manager_o,
    input  axi4_target_to_manager_t external_axi4_manager_i
);

  localparam int unsigned LOCAL_TARGET_COUNT = 2;
  localparam int unsigned CLINT_TARGET_INDEX = 0;
  localparam int unsigned EXTERNAL_TARGET_INDEX = 1;

  // 本地target地址数组使用AXI fabric宽度，具体地址由addr_map package统一提供。

  localparam logic [MEM_AXI_ADDR_WIDTH-1:0]
      LOCAL_TARGET_ADDRESS_BASE_ARRAY[LOCAL_TARGET_COUNT] = '{
        CLINT_BASE_ADDR,
        '0
      };
  localparam logic [MEM_AXI_ADDR_WIDTH-1:0]
      LOCAL_TARGET_ADDRESS_LAST_ARRAY[LOCAL_TARGET_COUNT] = '{
        CLINT_LAST_ADDR,
        '1
      };
  localparam logic
      LOCAL_TARGET_ADDRESS_SELECT_ENABLE_ARRAY[LOCAL_TARGET_COUNT] = '{
        1'b1,
        1'b0
      };

  logic system_rst_n;
  logic timer_interrupt;

  assign system_rst_no = system_rst_n;

  riscv32_reset_controller u_reset_controller (
      .clk_i  (clk_i),
      .rst_ni (rst_ni),
      .rst_no (system_rst_n)
  );

  axi4_manager_to_target_t instruction_axi4_manager;
  axi4_target_to_manager_t instruction_axi4_manager_response;
  axi4_manager_to_target_t data_axi4_manager;
  axi4_target_to_manager_t data_axi4_manager_response;

  axi4_manager_to_target_t merged_axi4_manager;
  axi4_target_to_manager_t merged_axi4_manager_response;

  axi4_manager_to_target_t local_target_manager_array[LOCAL_TARGET_COUNT];
  axi4_target_to_manager_t local_target_manager_response_array[LOCAL_TARGET_COUNT];

  riscv32_core #(
      .RESET_PC(RESET_PC)
  ) u_core (
      .clk_i                      (clk_i),
      .rst_ni                     (system_rst_n),
      .timer_interrupt_i          (timer_interrupt),
      .instruction_axi4_manager_o (instruction_axi4_manager),
      .instruction_axi4_manager_i (instruction_axi4_manager_response),
      .data_axi4_manager_o        (data_axi4_manager),
      .data_axi4_manager_i        (data_axi4_manager_response)
  );

  riscv32_axi4_arbiter u_axi4_arbiter (
      .clk_i                 (clk_i),
      .rst_ni                (system_rst_n),
      .instruction_manager_i (instruction_axi4_manager),
      .instruction_manager_o (instruction_axi4_manager_response),
      .data_manager_i        (data_axi4_manager),
      .data_manager_o        (data_axi4_manager_response),
      .downstream_manager_o  (merged_axi4_manager),
      .downstream_manager_i  (merged_axi4_manager_response)
  );

  riscv32_axi4_router #(
      .TARGET_COUNT                       (LOCAL_TARGET_COUNT),
      .TARGET_ADDRESS_BASE_ARRAY          (LOCAL_TARGET_ADDRESS_BASE_ARRAY),
      .TARGET_ADDRESS_LAST_ARRAY          (LOCAL_TARGET_ADDRESS_LAST_ARRAY),
      .TARGET_ADDRESS_SELECT_ENABLE_ARRAY (LOCAL_TARGET_ADDRESS_SELECT_ENABLE_ARRAY),
      .DEFAULT_TARGET_ENABLE              (1'b1),
      .DEFAULT_TARGET_INDEX               (EXTERNAL_TARGET_INDEX)
  ) u_local_address_router (
      .clk_i                  (clk_i),
      .rst_ni                 (system_rst_n),
      .upstream_manager_i     (merged_axi4_manager),
      .upstream_manager_o     (merged_axi4_manager_response),
      .target_manager_array_o (local_target_manager_array),
      .target_manager_array_i (local_target_manager_response_array)
  );

  riscv32_axi4_clint #(
      .CLINT_CLOCK_FREQ_HZ     (CLINT_CLOCK_FREQ_HZ),
      .MTIME_INCREMENT_FREQ_HZ (MTIME_INCREMENT_FREQ_HZ)
  ) u_clint (
      .clk_i             (clk_i),
      .rst_ni            (system_rst_n),
      .timer_interrupt_o (timer_interrupt),
      .axi_target_i      (local_target_manager_array[CLINT_TARGET_INDEX]),
      .axi_target_o      (local_target_manager_response_array[CLINT_TARGET_INDEX])
  );

  assign external_axi4_manager_o =
      local_target_manager_array[EXTERNAL_TARGET_INDEX];
  assign local_target_manager_response_array[EXTERNAL_TARGET_INDEX] =
      external_axi4_manager_i;

endmodule : riscv32_npc_system
