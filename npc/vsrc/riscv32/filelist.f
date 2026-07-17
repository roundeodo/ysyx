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
//   EXU -> completion mux: execute_result_t
//   EXU -> LSU: lsu_req_t
//   LSU/completion mux -> commit: writeback_result_t
// Channel valid/ready is separate from payload; P0 contains no stage register.

// TODO(BUS-FILELIST): 完成 riscv32_sim_mem 的完整握手、IFU/LSU 状态和 top 连接后，
// 在本 TODO 下方加入 riscv32_sim_mem.sv。随后拆出 riscv32_core.sv 和
// riscv32_sim_debug.sv，再把它们也加入这里。
// ${NPC_HOME}/vsrc/riscv32/riscv32_sim_mem.sv
// ${NPC_HOME}/vsrc/riscv32/riscv32_core.sv
// ${NPC_HOME}/vsrc/riscv32/riscv32_sim_debug.sv

// NOTE(P3): P2 协议测试通过后加入标准总线/SoC 模块：
//   riscv32_bus_adapter.sv, riscv32_soc.sv, timer/UART/interconnect modules。
// AXI 或 ysyx 指定协议只存在于 adapter/SoC 边界，core 继续使用稳定的内部 memory port。

// NOTE(P4): SoC 检查点稳定后加入 stage registers、forwarding、hazard 和 flush；
// 复用 P0 已定义的 valid/ready 通道，不改变 payload 的功能所有权。

// NOTE(P6): 流水线、cache 和 completion 路径稳定后再加入 rename、PRF、
// ROB、issue queue、LSQ 和 store buffer；最后在 P7 扩展为 two-wide。
