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

// TODO(P0-STA-MEMORY): 手册要求的单周期主频实验使用下面两个独立文件，但它们
// 只能加入 yosys-sta 的实验 RTL_FILES，绝不能取消注释加入正式 NPC filelist：
//   experiments/riscv32_sta_rom.sv - IFU 只读、组合返回；
//   experiments/riscv32_sta_ram.sv - LSU 可读写、组合读、posedge masked write。
// 两者各 256x32b。完成 STA 记录后，正式功能仿真继续使用 riscv32_sim_mem。

// TODO(P1-FILELIST): 完成 riscv32_sim_mem 的组合 adapter、IFU/LSU memory ports 和
// top 连接后，在本 TODO 下方加入 riscv32_sim_mem.sv。随后拆出 riscv32_core.sv 和
// riscv32_sim_debug.sv，再把它们也加入这里。P1 只移动 DPI 边界，不增加等待状态。
// ${NPC_HOME}/vsrc/riscv32/riscv32_sim_mem.sv
// ${NPC_HOME}/vsrc/riscv32/riscv32_core.sv
// ${NPC_HOME}/vsrc/riscv32/riscv32_sim_debug.sv

// TODO(P2-FILELIST): P1 全回归通过，并完成 IFU/LSU 本地事务状态后，在本 TODO
// 下方加入可综合 ROM/SRAM。先分别做 Harvard 端口；需要共享 slave 时再加入
// riscv32_simple_bus_arbiter.sv。P2 允许单条指令跨周期，但仍禁止多条指令同时在途。
// ${NPC_HOME}/vsrc/riscv32/riscv32_rom.sv
// ${NPC_HOME}/vsrc/riscv32/riscv32_sram.sv
// ${NPC_HOME}/vsrc/riscv32/riscv32_simple_bus_arbiter.sv

// NOTE(P3): P2 协议测试通过后加入标准总线/SoC 模块：
//   riscv32_bus_adapter.sv, riscv32_soc.sv, timer/UART/interconnect modules。
// AXI 或 ysyx 指定协议只存在于 adapter/SoC 边界，core 继续使用稳定的内部 memory port。

// NOTE(P4): SoC 检查点稳定后加入 stage registers、forwarding、hazard 和 flush；
// 复用 P0 已定义的 valid/ready 通道，不改变 payload 的功能所有权。

// NOTE(P6): 流水线、cache 和 completion 路径稳定后再加入 rename、PRF、
// ROB、issue queue、LSQ 和 store buffer；最后在 P7 扩展为 two-wide。
