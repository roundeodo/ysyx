// Standalone simulation shell. The core, AXI4 merge, and core-local CLINT are
// synthesizable; only the UART character sink, DPI memory, and debug hooks are
// simulation-specific.
module top
  import riscv32_addr_map_pkg::*;
  import riscv32_axi4_pkg::*;
  import riscv32_pkg::*;
#(
    parameter int unsigned SIM_IFU_READ_LATENCY    = 1,
    parameter int unsigned SIM_LSU_READ_LATENCY    = 1,
    parameter int unsigned SIM_LSU_WRITE_LATENCY   = 1,
    parameter int unsigned SIM_RANDOM_LATENCY_MAX  = 20,
    parameter program_counter_t RESET_PC            = program_counter_t'(32'h8000_0000)
) (
    input  logic clk,
    input  logic rstn
);

  localparam int unsigned SIM_TARGET_COUNT       = 2;
  localparam int unsigned UART_TARGET_INDEX      = 0;
  localparam int unsigned MEMORY_TARGET_INDEX    = 1;

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

  riscv32_npc_system #(
      .RESET_PC(RESET_PC)
  ) u_npc_system (
      .clk_i                   (clk),
      .rst_ni                  (rstn),
      .system_rst_no           (),
      .external_axi4_manager_o (npc_external_axi4_manager),
      .external_axi4_manager_i (npc_external_axi4_response)
  );

  riscv32_axi4_router #(
      .TARGET_COUNT                       (SIM_TARGET_COUNT),
      .TARGET_ADDRESS_BASE_ARRAY          (SIM_TARGET_ADDRESS_BASE_ARRAY),
      .TARGET_ADDRESS_LAST_ARRAY          (SIM_TARGET_ADDRESS_LAST_ARRAY),
      .TARGET_ADDRESS_SELECT_ENABLE_ARRAY (SIM_TARGET_ADDRESS_SELECT_ENABLE_ARRAY),
      .DEFAULT_TARGET_ENABLE              (1'b1),
      .DEFAULT_TARGET_INDEX               (MEMORY_TARGET_INDEX)
  ) u_sim_address_router (
      .clk_i                   (clk),
      .rst_ni                  (rstn),
      .upstream_manager_i     (npc_external_axi4_manager),
      .upstream_manager_o     (npc_external_axi4_response),
      .target_manager_array_o (sim_target_manager_array),
      .target_manager_array_i (sim_target_response_array)
  );

  riscv32_axi4_uart_sim u_uart_sim (
      .clk_i                   (clk),
      .rst_ni                  (rstn),
      .uart_axi_i (sim_target_manager_array[UART_TARGET_INDEX]),
      .uart_axi_o (sim_target_response_array[UART_TARGET_INDEX])
  );

  riscv32_axi4_sim_mem #(
      .IFU_READ_LATENCY_CYCLES   (SIM_IFU_READ_LATENCY),
      .LSU_READ_LATENCY_CYCLES   (SIM_LSU_READ_LATENCY),
      .LSU_WRITE_LATENCY_CYCLES  (SIM_LSU_WRITE_LATENCY),
      .RANDOM_LATENCY_MAX_CYCLES (SIM_RANDOM_LATENCY_MAX)
  ) u_sim_mem (
      .clk_i                   (clk),
      .rst_ni                  (rstn),
      .mem_axi_i (sim_target_manager_array[MEMORY_TARGET_INDEX]),
      .mem_axi_o (sim_target_response_array[MEMORY_TARGET_INDEX])
  );

  import "DPI-C" context function void npc_set_dpi_scope();
  import "DPI-C" context function void ebreak_halt();

  initial begin
    npc_set_dpi_scope();
  end

  export "DPI-C" function npc_get_pc_dpi;
  export "DPI-C" function npc_get_inst_dpi;
  export "DPI-C" function npc_get_commit_valid_dpi;
  export "DPI-C" function npc_get_commit_pc_dpi;
  export "DPI-C" function npc_get_commit_inst_dpi;
  export "DPI-C" function npc_get_commit_next_pc_dpi;
  export "DPI-C" function npc_get_gpr_dpi;
  export "DPI-C" function npc_get_mstatus_dpi;
  export "DPI-C" function npc_get_mtvec_dpi;
  export "DPI-C" function npc_get_mepc_dpi;
  export "DPI-C" function npc_get_mcause_dpi;
  export "DPI-C" function npc_get_mtval_dpi;

  function longint unsigned npc_get_pc_dpi();
    npc_get_pc_dpi = 64'($unsigned(u_npc_system.u_core.idu_fetch_entry.pc));
  endfunction

  function int npc_get_inst_dpi();
    npc_get_inst_dpi = u_npc_system.u_core.idu_fetch_entry.instruction;
  endfunction

  function int npc_get_commit_valid_dpi();
    npc_get_commit_valid_dpi = int'(u_npc_system.u_core.commit_valid);
  endfunction

  function longint unsigned npc_get_commit_pc_dpi();
    npc_get_commit_pc_dpi = 64'($unsigned(u_npc_system.u_core.commit.pc));
  endfunction

  function int npc_get_commit_inst_dpi();
    npc_get_commit_inst_dpi = u_npc_system.u_core.commit.instruction;
  endfunction

  function longint unsigned npc_get_commit_next_pc_dpi();
    if (u_npc_system.u_core.selected_redirect_req_valid &&
        u_npc_system.u_core.commit_valid &&
        (u_npc_system.u_core.selected_redirect_req.source_pc ==
         u_npc_system.u_core.commit.pc)) begin
      npc_get_commit_next_pc_dpi =
          64'($unsigned(u_npc_system.u_core.selected_redirect_req.target_pc));
    end else begin
      npc_get_commit_next_pc_dpi = 64'($unsigned(u_npc_system.u_core.commit.next_pc));
    end
  endfunction

  function longint unsigned npc_get_gpr_dpi(input int index);
    if ((index <= 0) || (index >= ARCH_REG_COUNT)) begin
      npc_get_gpr_dpi = '0;
    end else begin
      npc_get_gpr_dpi = 64'($unsigned(u_npc_system.u_core.u_regfile.gpr_array_q[index]));
    end
  endfunction

  function longint unsigned npc_get_mstatus_dpi();
    npc_get_mstatus_dpi = 64'($unsigned(u_npc_system.u_core.u_csr_file.mstatus_value));
  endfunction

  function longint unsigned npc_get_mtvec_dpi();
    npc_get_mtvec_dpi = 64'($unsigned(u_npc_system.u_core.u_csr_file.mtvec_value));
  endfunction

  function longint unsigned npc_get_mepc_dpi();
    npc_get_mepc_dpi = 64'($unsigned(u_npc_system.u_core.u_csr_file.mepc_value));
  endfunction

  function longint unsigned npc_get_mcause_dpi();
    npc_get_mcause_dpi = 64'($unsigned(u_npc_system.u_core.u_csr_file.mcause_value));
  endfunction

  function longint unsigned npc_get_mtval_dpi();
    npc_get_mtval_dpi = 64'($unsigned(u_npc_system.u_core.u_csr_file.mtval_q));
  endfunction

  always_ff @(posedge clk) begin
    if (u_npc_system.u_core.commit_valid &&
        (u_npc_system.u_core.commit.system_op == SYS_EBREAK)) begin
      ebreak_halt();
    end
  end

  `include "riscv32_perf_dpi.svh"

endmodule : top
