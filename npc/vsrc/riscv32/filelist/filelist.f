// DESIGN AUTHORITY: ${NPC_HOME}/vsrc/riscv32/doc/ARCHITECTURE_PLAN.md
// D018 requires a runnable checkpoint after every migration step. The entries
// below are the active P0 single-cycle NPC, not the final OoO source layout.

${NPC_HOME}/vsrc/riscv32/common/riscv32_pkg.sv

${NPC_HOME}/vsrc/riscv32/core/riscv32_arch_regfile.sv
${NPC_HOME}/vsrc/riscv32/core/riscv32_csr_file.sv
${NPC_HOME}/vsrc/riscv32/core/riscv32_idu.sv
${NPC_HOME}/vsrc/riscv32/core/riscv32_exu.sv
${NPC_HOME}/vsrc/riscv32/core/riscv32_lsu.sv
${NPC_HOME}/vsrc/riscv32/core/riscv32_completion_mux.sv
${NPC_HOME}/vsrc/riscv32/core/riscv32_commit.sv
${NPC_HOME}/vsrc/riscv32/core/riscv32_trap_controller.sv
${NPC_HOME}/vsrc/riscv32/core/riscv32_redirect_arbiter.sv
${NPC_HOME}/vsrc/riscv32/core/riscv32_ifu.sv
${NPC_HOME}/vsrc/riscv32/core/riscv32_core.sv

${NPC_HOME}/vsrc/riscv32/system/riscv32_axi_lite_arbiter.sv
${NPC_HOME}/vsrc/riscv32/system/riscv32_axi_lite_xbar.sv
${NPC_HOME}/vsrc/riscv32/system/riscv32_npc_axi_core_boundary.sv
${NPC_HOME}/vsrc/riscv32/system/riscv32_npc_axi.sv
${NPC_HOME}/vsrc/riscv32/system/peripheral/riscv32_axi_lite_clint.sv

${NPC_HOME}/vsrc/riscv32/sim/riscv32_axi_lite_uart_sim.sv
${NPC_HOME}/vsrc/riscv32/sim/riscv32_sim_mem.sv
${NPC_HOME}/vsrc/riscv32/sim/top.sv

// P0 typed channel conversion completed in this order:
//   IFU -> IDU: fetch_entry_t
//   IDU -> EXU: decoded_uop_t + register operand values
//   EXU -> completion mux: execute_result_t
//   EXU -> LSU: lsu_req_t
//   LSU/completion mux -> commit: writeback_result_t
// Channel valid/ready is separate from payload; P0 contains no stage register.

// Simulation-only DPI debug remains in top at this checkpoint. It will move to
// riscv32_sim_debug when the SoC shell introduces multiple simulation adapters.

// P3B checkpoint: IFU/LSU arbitration, address routing, simulation UART, and
// CLINT mtime are integrated. The remaining DPI platform slave contains PMEM;
// a later SoC checkpoint replaces it with synthesizable SRAM integration.

// NOTE(P4): SoC 检查点稳定后加入 stage registers、forwarding、hazard 和 flush；
// 复用 P0 已定义的 valid/ready 通道，不改变 payload 的功能所有权。

// NOTE(P6): 流水线、cache 和 completion 路径稳定后再加入 rename、PRF、
// ROB、issue queue、LSQ 和 store buffer；最后在 P7 扩展为 two-wide。
