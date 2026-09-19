// 正式配置宏由Makefile通过NPC_CONFIG唯一传入，STA filelist只负责源文件顺序。
// 配置、地址与协议类型必须先于消费它们的模块。
${NPC_HOME}/vsrc/riscv32/common/riscv_config_pkg.sv
${NPC_HOME}/vsrc/riscv32/common/riscv32_addr_map_pkg.sv
${NPC_HOME}/vsrc/riscv32/common/riscv32_axi4_pkg.sv
${NPC_HOME}/vsrc/riscv32/common/riscv32_ysyx_soc_axi4_pkg.sv
${NPC_HOME}/vsrc/riscv32/common/riscv32_pkg.sv

// 前端：属性检查、I-cache 和取指缓冲。
${NPC_HOME}/vsrc/riscv32/core/frontend/riscv32_pma.sv
${NPC_HOME}/vsrc/riscv32/core/frontend/riscv32_icache_tag_array.sv
${NPC_HOME}/vsrc/riscv32/core/frontend/riscv32_icache_data_array.sv
${NPC_HOME}/vsrc/riscv32/core/frontend/riscv32_icache_axi.sv
${NPC_HOME}/vsrc/riscv32/core/frontend/riscv32_icache_miss_unit.sv
${NPC_HOME}/vsrc/riscv32/core/frontend/riscv32_icache.sv
${NPC_HOME}/vsrc/riscv32/core/frontend/riscv32_fetch_buffer.sv
// 数据存储：D-cache、uncached 和路由。
${NPC_HOME}/vsrc/riscv32/core/memory/riscv32_dcache_tag_array.sv
${NPC_HOME}/vsrc/riscv32/core/memory/riscv32_dcache_data_array.sv
${NPC_HOME}/vsrc/riscv32/core/memory/riscv32_dcache_axi.sv
${NPC_HOME}/vsrc/riscv32/core/memory/riscv32_dcache_miss_unit.sv
${NPC_HOME}/vsrc/riscv32/core/memory/riscv32_dcache.sv
${NPC_HOME}/vsrc/riscv32/core/memory/riscv32_uncached_axi.sv
${NPC_HOME}/vsrc/riscv32/core/memory/riscv32_data_mem.sv

// 处理器核：读数、执行、提交与控制。
${NPC_HOME}/vsrc/riscv32/core/decode/riscv32_regfile.sv
${NPC_HOME}/vsrc/riscv32/core/writeback/riscv32_pmu.sv
${NPC_HOME}/vsrc/riscv32/core/writeback/riscv32_csr_file.sv
${NPC_HOME}/vsrc/riscv32/core/decode/riscv32_idu.sv
${NPC_HOME}/vsrc/riscv32/core/frontend/riscv32_bht.sv
${NPC_HOME}/vsrc/riscv32/core/frontend/riscv32_btb.sv
${NPC_HOME}/vsrc/riscv32/core/frontend/riscv32_ras.sv
${NPC_HOME}/vsrc/riscv32/core/frontend/riscv32_branch_predictor.sv
${NPC_HOME}/vsrc/riscv32/core/execute/riscv32_id_ex_reg.sv
${NPC_HOME}/vsrc/riscv32/core/control/riscv32_redirect_stage.sv
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

// 系统边界：AXI、CLINT、复位与 SoC 适配。
${NPC_HOME}/vsrc/riscv32/system/riscv32_axi4_arbiter.sv
${NPC_HOME}/vsrc/riscv32/system/riscv32_axi4_router.sv
${NPC_HOME}/vsrc/riscv32/system/peripheral/riscv32_axi4_clint.sv
${NPC_HOME}/vsrc/riscv32/system/riscv32_reset_controller.sv
${NPC_HOME}/vsrc/riscv32/system/riscv32_core_reset_boundary.sv
${NPC_HOME}/vsrc/riscv32/system/riscv32_npc_system.sv
${NPC_HOME}/vsrc/riscv32/system/riscv32_axi4_soc_width_converter.sv
${NPC_HOME}/vsrc/riscv32/system/riscv32_npc_axi.sv
