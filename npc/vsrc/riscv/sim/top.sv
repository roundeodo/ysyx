// Standalone simulation shell. The core, AXI4 merge, and core-local CLINT are
// synthesizable; only the UART character sink, DPI memory, and debug hooks are
// simulation-specific.
module top
  import riscv_addr_map_pkg::*;
  import riscv_axi4_pkg::*;
  import riscv_pkg::*;
#(
    parameter int unsigned      SIM_IFU_READ_LATENCY   = 1,
    parameter int unsigned      SIM_LSU_READ_LATENCY   = 1,
    parameter int unsigned      SIM_LSU_WRITE_LATENCY  = 1,
    parameter int unsigned      SIM_RANDOM_LATENCY_MAX = 20,
    parameter program_counter_t RESET_PC               = program_counter_t'(32'h8000_0000)
) (
    input logic clk,
    input logic rstn
);

  localparam int unsigned SIM_TARGET_COUNT = 2;
  localparam int unsigned UART_TARGET_INDEX = 0;
  localparam int unsigned MEMORY_TARGET_INDEX = 1;

  // 仿真壳只消费设计配置，不应自行复制宽度或寄存器数量。

  // UART uses its real platform window. Every other address reaches the DPI
  // memory target so the standalone environment can continue to run flat PMEM.
  localparam logic [MEM_AXI_ADDR_WIDTH-1:0] SIM_TARGET_ADDRESS_BASE_ARRAY[SIM_TARGET_COUNT] = '{
      UART_BASE_ADDR,
      '0
  };
  localparam logic [MEM_AXI_ADDR_WIDTH-1:0] SIM_TARGET_ADDRESS_LAST_ARRAY[SIM_TARGET_COUNT] = '{
      UART_LAST_ADDR,
      '1
  };
  localparam logic SIM_TARGET_ADDRESS_SELECT_ENABLE_ARRAY[SIM_TARGET_COUNT] = '{1'b1, 1'b0};

  axi4_manager_to_target_t npc_external_axi4_manager;
  axi4_target_to_manager_t npc_external_axi4_response;

  axi4_manager_to_target_t sim_target_manager_array[SIM_TARGET_COUNT];
  axi4_target_to_manager_t sim_target_response_array[SIM_TARGET_COUNT];

  riscv_npc_system #(
      .RESET_PC(RESET_PC)
  ) u_npc_system (
      .clk_i                  (clk),
      .rst_ni                 (rstn),
      .external_axi4_manager_o(npc_external_axi4_manager),
      .external_axi4_manager_i(npc_external_axi4_response)
  );

  riscv_axi4_address_router #(
      .TARGET_COUNT                      (SIM_TARGET_COUNT),
      .TARGET_ADDRESS_BASE_ARRAY         (SIM_TARGET_ADDRESS_BASE_ARRAY),
      .TARGET_ADDRESS_LAST_ARRAY         (SIM_TARGET_ADDRESS_LAST_ARRAY),
      .TARGET_ADDRESS_SELECT_ENABLE_ARRAY(SIM_TARGET_ADDRESS_SELECT_ENABLE_ARRAY),
      .DEFAULT_TARGET_ENABLE             (1'b1),
      .DEFAULT_TARGET_INDEX              (MEMORY_TARGET_INDEX)
  ) u_sim_address_router (
      .clk_i                 (clk),
      .rst_ni                (rstn),
      .upstream_manager_i    (npc_external_axi4_manager),
      .upstream_manager_o    (npc_external_axi4_response),
      .target_manager_array_o(sim_target_manager_array),
      .target_manager_array_i(sim_target_response_array)
  );

  riscv_axi4_uart_sim u_uart_sim (
      .clk_i     (clk),
      .rst_ni    (rstn),
      .uart_axi_i(sim_target_manager_array[UART_TARGET_INDEX]),
      .uart_axi_o(sim_target_response_array[UART_TARGET_INDEX])
  );

  riscv_axi4_sim_mem #(
      .IFU_READ_LATENCY  (SIM_IFU_READ_LATENCY),
      .LSU_READ_LATENCY  (SIM_LSU_READ_LATENCY),
      .LSU_WRITE_LATENCY (SIM_LSU_WRITE_LATENCY),
      .RANDOM_LATENCY_MAX(SIM_RANDOM_LATENCY_MAX)
  ) u_sim_mem (
      .clk_i    (clk),
      .rst_ni   (rstn),
      .mem_axi_i(sim_target_manager_array[MEMORY_TARGET_INDEX]),
      .mem_axi_o(sim_target_response_array[MEMORY_TARGET_INDEX])
  );

  `include "riscv_sim_debug.svh"

  always_ff @(posedge clk) begin
    if (u_npc_system.u_core.commit_valid &&
        (u_npc_system.u_core.commit.system_op == SYS_EBREAK)) begin
      ebreak_halt();
    end
  end

endmodule : top
