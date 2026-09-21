// 仅仿真时实例化性能监视模块。STA filelist不定义此开关，因此综合设计中不存在该实例。
+define+NPC_ENABLE_SIM_MONITOR
+incdir+${NPC_HOME}/vsrc/riscv32/sim

// 正式配置宏由Makefile通过NPC_CONFIG唯一传入，filelist不得硬编码RV32/RV64。
// package必须位于所有import它们的模块之前。
${NPC_HOME}/vsrc/riscv32/common/riscv_config_pkg.sv
${NPC_HOME}/vsrc/riscv32/common/riscv32_addr_map_pkg.sv
${NPC_HOME}/vsrc/riscv32/common/riscv32_axi4_pkg.sv
${NPC_HOME}/vsrc/riscv32/common/riscv32_ysyx_soc_axi4_pkg.sv
${NPC_HOME}/vsrc/riscv32/common/riscv32_pkg.sv

// 前端存储阵列、miss处理和AXI4 refill路径。
${NPC_HOME}/vsrc/riscv32/core/frontend/riscv32_pma.sv
${NPC_HOME}/vsrc/riscv32/core/frontend/riscv32_icache_tag_array.sv
${NPC_HOME}/vsrc/riscv32/core/frontend/riscv32_icache_data_array.sv
${NPC_HOME}/vsrc/riscv32/core/frontend/riscv32_icache_axi.sv
${NPC_HOME}/vsrc/riscv32/core/frontend/riscv32_icache_miss_unit.sv
${NPC_HOME}/vsrc/riscv32/core/frontend/riscv32_icache.sv
${NPC_HOME}/vsrc/riscv32/core/frontend/riscv32_fetch_buffer.sv

// 数据存储子系统：同步阵列、write-back miss路径、PMA路由和uncached旁路。
${NPC_HOME}/vsrc/riscv32/core/memory/riscv32_dcache_tag_array.sv
${NPC_HOME}/vsrc/riscv32/core/memory/riscv32_dcache_data_array.sv
${NPC_HOME}/vsrc/riscv32/core/memory/riscv32_dcache_axi.sv
${NPC_HOME}/vsrc/riscv32/core/memory/riscv32_dcache_miss_unit.sv
${NPC_HOME}/vsrc/riscv32/core/memory/riscv32_dcache.sv
${NPC_HOME}/vsrc/riscv32/core/memory/riscv32_uncached_axi.sv
${NPC_HOME}/vsrc/riscv32/core/memory/riscv32_data_mem.sv

// 处理器核：译码/读数、预测器、执行/完成和提交控制。
${NPC_HOME}/vsrc/riscv32/core/decode/riscv32_regfile.sv
${NPC_HOME}/vsrc/riscv32/core/writeback/riscv32_pmu.sv
${NPC_HOME}/vsrc/riscv32/core/writeback/riscv32_csr_file.sv
${NPC_HOME}/vsrc/riscv32/core/decode/riscv32_idu.sv
${NPC_HOME}/vsrc/riscv32/core/frontend/riscv32_bht.sv
${NPC_HOME}/vsrc/riscv32/core/frontend/riscv32_btb.sv
${NPC_HOME}/vsrc/riscv32/core/frontend/riscv32_ras.sv
${NPC_HOME}/vsrc/riscv32/core/frontend/riscv32_branch_predictor.sv
${NPC_HOME}/vsrc/riscv32/core/execute/riscv32_id_ex_reg.sv
${NPC_HOME}/vsrc/riscv32/core/control/riscv32_redirect_mux.sv
${NPC_HOME}/vsrc/riscv32/core/control/riscv32_hazard_ctrl.sv
${NPC_HOME}/vsrc/riscv32/core/execute/riscv32_exu.sv
${NPC_HOME}/vsrc/riscv32/core/execute/riscv32_ex_result_reg.sv
${NPC_HOME}/vsrc/riscv32/core/memory/riscv32_lsu.sv
${NPC_HOME}/vsrc/riscv32/core/writeback/riscv32_completion_mux.sv
${NPC_HOME}/vsrc/riscv32/core/writeback/riscv32_wb_reg.sv
${NPC_HOME}/vsrc/riscv32/core/writeback/riscv32_commit.sv
${NPC_HOME}/vsrc/riscv32/core/control/riscv32_interrupt_ctrl.sv
${NPC_HOME}/vsrc/riscv32/core/control/riscv32_trap_ctrl.sv
${NPC_HOME}/vsrc/riscv32/core/frontend/riscv32_ifu.sv
${NPC_HOME}/vsrc/riscv32/core/decode/riscv32_operand_mux.sv
${NPC_HOME}/vsrc/riscv32/core/control/riscv32_fence_i_ctrl.sv
${NPC_HOME}/vsrc/riscv32/core/riscv32_core.sv

// 完整AXI4系统集成。
${NPC_HOME}/vsrc/riscv32/system/riscv32_axi4_arbiter.sv
${NPC_HOME}/vsrc/riscv32/system/riscv32_axi4_router.sv
${NPC_HOME}/vsrc/riscv32/system/peripheral/riscv32_axi4_clint.sv
${NPC_HOME}/vsrc/riscv32/system/riscv32_reset_controller.sv
${NPC_HOME}/vsrc/riscv32/system/riscv32_core_reset_boundary.sv
${NPC_HOME}/vsrc/riscv32/system/riscv32_npc_system.sv
${NPC_HOME}/vsrc/riscv32/system/riscv32_axi4_soc_width_converter.sv
${NPC_HOME}/vsrc/riscv32/system/riscv32_npc_axi.sv

// 仅仿真使用的监视模块和AXI4 target。
${NPC_HOME}/vsrc/riscv32/sim/riscv32_sim_perf_monitor.sv
${NPC_HOME}/vsrc/riscv32/sim/riscv32_sim_icache_monitor.sv
${NPC_HOME}/vsrc/riscv32/sim/riscv32_sim_dcache_monitor.sv
${NPC_HOME}/vsrc/riscv32/sim/riscv32_sim_cache_wait_monitor.sv
${NPC_HOME}/vsrc/riscv32/sim/riscv32_axi4_uart_sim.sv
${NPC_HOME}/vsrc/riscv32/sim/riscv32_axi4_sim_mem.sv
${NPC_HOME}/vsrc/riscv32/sim/top.sv

${NPC_HOME}/vsrc/riscv32/sim/riscv32_sim_issue_window_monitor.sv
