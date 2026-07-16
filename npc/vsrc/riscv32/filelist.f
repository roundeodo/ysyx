// DESIGN AUTHORITY: ${NPC_HOME}/vsrc/riscv32/ARCHITECTURE_PLAN.md
// D018 requires a runnable checkpoint after every migration step. The entries
// below are the active P0 single-cycle NPC, not the final OoO source layout.

${NPC_HOME}/vsrc/riscv32/riscv32_pkg.sv
${NPC_HOME}/vsrc/riscv32/riscv32_arch_regfile.sv
${NPC_HOME}/vsrc/riscv32/riscv32_csr_file.sv
${NPC_HOME}/vsrc/riscv32/riscv32_idu.sv
${NPC_HOME}/vsrc/riscv32/riscv32_exu.sv
${NPC_HOME}/vsrc/riscv32/riscv32_lsu.sv
${NPC_HOME}/vsrc/riscv32/riscv32_completion_mux.sv
${NPC_HOME}/vsrc/riscv32/riscv32_commit.sv
${NPC_HOME}/vsrc/riscv32/riscv32_trap_controller.sv
${NPC_HOME}/vsrc/riscv32/riscv32_redirect_arbiter.sv
${NPC_HOME}/vsrc/riscv32/riscv32_ifu.sv
${NPC_HOME}/vsrc/riscv32/top.sv

// P0 typed channel conversion completed in this order:
//   IFU -> IDU: fetch_entry_t
//   IDU -> EXU: decoded_uop_t + register operand values
//   EXU -> LSU/direct completion: execute_result_t
//   LSU/direct completion -> commit: writeback_result_t
// Channel valid/ready is separate from payload; P0 contains no stage register.

// NOTE(P1): P0 全回归通过后加入：
//   riscv32_core.sv, riscv32_sim_mem.sv, riscv32_sim_debug.sv。
// 先保持组合 memory adapter，只把 DPI 移出 core；不要同时引入总线等待状态。

// NOTE(P2): P1 全回归通过后加入简单总线与真实 memory：
//   riscv32_simple_bus_arbiter.sv, riscv32_sram.sv, riscv32_rom.sv。
// 此时允许单条指令因 memory stall 跨多个周期，但仍然禁止多条指令同时在途。

// NOTE(P3): P2 协议测试通过后加入标准总线/SoC 模块：
//   riscv32_bus_adapter.sv, riscv32_soc.sv, timer/UART/interconnect modules。
// AXI 或 ysyx 指定协议只存在于 adapter/SoC 边界，core 继续使用稳定的内部 memory port。

// NOTE(P4): SoC 检查点稳定后加入 stage registers、forwarding、hazard 和 flush；
// 复用 P0 已定义的 valid/ready 通道，不改变 payload 的功能所有权。

// NOTE(P6): 流水线、cache 和 completion 路径稳定后再加入 rename、PRF、
// ROB、issue queue、LSQ 和 store buffer；最后在 P7 扩展为 two-wide。
