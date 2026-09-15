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
${NPC_HOME}/vsrc/riscv32/core/frontend/riscv32_icache_refill_axi4_master.sv
${NPC_HOME}/vsrc/riscv32/core/frontend/riscv32_icache_miss_unit.sv
${NPC_HOME}/vsrc/riscv32/core/frontend/riscv32_icache.sv
${NPC_HOME}/vsrc/riscv32/core/frontend/riscv32_fetch_buffer.sv

// 数据存储子系统：同步阵列、write-back miss路径、PMA路由和uncached旁路。
${NPC_HOME}/vsrc/riscv32/core/memory/riscv32_dcache_tag_array.sv
${NPC_HOME}/vsrc/riscv32/core/memory/riscv32_dcache_data_array.sv
${NPC_HOME}/vsrc/riscv32/core/memory/riscv32_dcache_line_axi4_master.sv
${NPC_HOME}/vsrc/riscv32/core/memory/riscv32_dcache_miss_unit.sv
${NPC_HOME}/vsrc/riscv32/core/memory/riscv32_dcache.sv
${NPC_HOME}/vsrc/riscv32/core/memory/riscv32_uncached_axi4_master.sv
${NPC_HOME}/vsrc/riscv32/core/memory/riscv32_data_memory_subsystem.sv

// 处理器核。
${NPC_HOME}/vsrc/riscv32/core/riscv32_arch_regfile.sv
${NPC_HOME}/vsrc/riscv32/core/riscv32_pmu.sv
${NPC_HOME}/vsrc/riscv32/core/riscv32_csr_file.sv
${NPC_HOME}/vsrc/riscv32/core/riscv32_idu.sv
${NPC_HOME}/vsrc/riscv32/core/riscv32_decode_stage.sv
${NPC_HOME}/vsrc/riscv32/core/riscv32_register_read_stage.sv
${NPC_HOME}/vsrc/riscv32/core/frontend/riscv32_branch_history_table.sv
${NPC_HOME}/vsrc/riscv32/core/frontend/riscv32_branch_target_buffer.sv
${NPC_HOME}/vsrc/riscv32/core/frontend/riscv32_return_address_stack.sv
${NPC_HOME}/vsrc/riscv32/core/frontend/riscv32_fetch_control_flow_predictor.sv
${NPC_HOME}/vsrc/riscv32/core/riscv32_decode_execute_stage.sv
${NPC_HOME}/vsrc/riscv32/core/riscv32_frontend_redirect_register.sv
${NPC_HOME}/vsrc/riscv32/core/riscv32_pipeline_hazard_controller.sv
${NPC_HOME}/vsrc/riscv32/core/riscv32_exu.sv
${NPC_HOME}/vsrc/riscv32/core/riscv32_execute_result_stage.sv
${NPC_HOME}/vsrc/riscv32/core/riscv32_lsu.sv
${NPC_HOME}/vsrc/riscv32/core/riscv32_completion_mux.sv
${NPC_HOME}/vsrc/riscv32/core/riscv32_writeback_stage.sv
${NPC_HOME}/vsrc/riscv32/core/riscv32_commit.sv
${NPC_HOME}/vsrc/riscv32/core/riscv32_interrupt_controller.sv
${NPC_HOME}/vsrc/riscv32/core/riscv32_trap_controller.sv
${NPC_HOME}/vsrc/riscv32/core/riscv32_redirect_arbiter.sv
${NPC_HOME}/vsrc/riscv32/core/riscv32_ifu.sv
${NPC_HOME}/vsrc/riscv32/core/riscv32_core.sv

// 完整AXI4系统集成。
${NPC_HOME}/vsrc/riscv32/system/riscv32_axi4_core_merge.sv
${NPC_HOME}/vsrc/riscv32/system/riscv32_axi4_address_router.sv
${NPC_HOME}/vsrc/riscv32/system/riscv32_axi4_error_target.sv
${NPC_HOME}/vsrc/riscv32/system/peripheral/riscv32_axi4_clint.sv
${NPC_HOME}/vsrc/riscv32/system/riscv32_reset_controller.sv
${NPC_HOME}/vsrc/riscv32/system/riscv32_core_reset_boundary.sv
${NPC_HOME}/vsrc/riscv32/system/riscv32_npc_system.sv
${NPC_HOME}/vsrc/riscv32/system/riscv32_axi4_soc_width_converter.sv
${NPC_HOME}/vsrc/riscv32/system/riscv32_npc_axi.sv

// 仅仿真使用的监视模块和AXI4 target。
${NPC_HOME}/vsrc/riscv32/sim/riscv32_sim_performance_monitor.sv
${NPC_HOME}/vsrc/riscv32/sim/riscv32_sim_icache_performance_monitor.sv
${NPC_HOME}/vsrc/riscv32/sim/riscv32_sim_dcache_performance_monitor.sv
${NPC_HOME}/vsrc/riscv32/sim/riscv32_axi4_uart_sim.sv
${NPC_HOME}/vsrc/riscv32/sim/riscv32_axi4_sim_mem.sv
${NPC_HOME}/vsrc/riscv32/sim/top.sv

${NPC_HOME}/vsrc/riscv32/sim/riscv32_sim_issue_window_monitor.sv
