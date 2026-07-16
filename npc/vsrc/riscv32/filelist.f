// DESIGN AUTHORITY: ${NPC_HOME}/vsrc/riscv32/ARCHITECTURE_PLAN.md
// D018 requires a runnable checkpoint after every migration step. The entries
// below are the active P0 single-cycle NPC, not the final OoO source layout.

${NPC_HOME}/vsrc/riscv32/riscv32_pkg.sv
${NPC_HOME}/vsrc/riscv32/RegisterFile.sv
${NPC_HOME}/vsrc/riscv32/riscv32_CSR.sv
${NPC_HOME}/vsrc/riscv32/riscv32_idu.sv
${NPC_HOME}/vsrc/riscv32/riscv32_EXU.sv
${NPC_HOME}/vsrc/riscv32/riscv32_RDU.sv
${NPC_HOME}/vsrc/riscv32/riscv32_IFU.sv
${NPC_HOME}/vsrc/riscv32/riscv32_LSU.sv
${NPC_HOME}/vsrc/riscv32/riscv32_WBU.sv
${NPC_HOME}/vsrc/riscv32/top.sv

// TODO(HP-FILELIST-P0): 当前只做单周期模块间 typed bundle 改造。
// 每次只修改一条 producer-consumer 边界，并在本 TODO 正下方记录已完成顺序：
//   IFU -> IDU: fetch_entry_t
//   IDU -> EXU: decoded_uop_t + register operand values
//   EXU -> LSU: execute result payload
//   LSU -> commit/WBU: architectural result payload
// 这一阶段禁止加入 pipeline register、ROB、rename、issue queue 或多发射 lane。

// TODO(HP-FILELIST-P1): P0 全回归通过后，在本 TODO 正下方加入：
//   riscv32_core.sv, riscv32_sim_mem.sv, riscv32_sim_debug.sv。
// 先保持组合 memory adapter，只把 DPI 移出 core；不要同时引入总线等待状态。

// TODO(HP-FILELIST-P2): P1 全回归通过后，在本 TODO 正下方加入简单总线与真实 memory：
//   riscv32_simple_bus_arbiter.sv, riscv32_sram.sv, riscv32_rom.sv。
// 此时允许单条指令因 memory stall 跨多个周期，但仍然禁止多条指令同时在途。

// TODO(HP-FILELIST-P3): P2 协议测试通过后，在本 TODO 正下方加入标准总线/SoC 模块：
//   riscv32_bus_adapter.sv, riscv32_soc.sv, timer/UART/interconnect modules。
// AXI 或 ysyx 指定协议只存在于 adapter/SoC 边界，core 继续使用稳定的内部 memory port。

// TODO(HP-FILELIST-P4): SoC 检查点稳定后再加入 in-order pipeline stage modules、
// forwarding/hazard/flush/commit；从这里开始使用独立 valid/ready。

// TODO(HP-FILELIST-P6): 流水线、cache 和 completion 路径稳定后再加入 rename、PRF、
// ROB、issue queue、LSQ 和 store buffer；最后在 P7 扩展为 two-wide。
