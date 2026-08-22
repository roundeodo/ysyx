// 正式配置宏由Makefile通过NPC_CONFIG唯一传入，STA filelist只负责源文件顺序。
${NPC_HOME}/vsrc/riscv32/common/riscv_config_pkg.sv
${NPC_HOME}/vsrc/riscv32/common/riscv32_addr_map_pkg.sv
${NPC_HOME}/vsrc/riscv32/common/riscv32_axi4_pkg.sv
${NPC_HOME}/vsrc/riscv32/common/riscv32_ysyx_soc_axi4_pkg.sv
${NPC_HOME}/vsrc/riscv32/common/riscv32_pkg.sv

${NPC_HOME}/vsrc/riscv32/core/frontend/riscv32_pma.sv
${NPC_HOME}/vsrc/riscv32/core/frontend/riscv32_icache_tag_array.sv
${NPC_HOME}/vsrc/riscv32/core/frontend/riscv32_icache_data_array.sv
${NPC_HOME}/vsrc/riscv32/core/frontend/riscv32_icache_refill_axi4_master.sv
${NPC_HOME}/vsrc/riscv32/core/frontend/riscv32_icache_miss_unit.sv
${NPC_HOME}/vsrc/riscv32/core/frontend/riscv32_icache.sv
${NPC_HOME}/vsrc/riscv32/core/memory/riscv32_uncached_axi4_master.sv

${NPC_HOME}/vsrc/riscv32/core/riscv32_arch_regfile.sv
${NPC_HOME}/vsrc/riscv32/core/riscv32_pmu.sv
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

${NPC_HOME}/vsrc/riscv32/system/riscv32_axi4_core_merge.sv
${NPC_HOME}/vsrc/riscv32/system/riscv32_axi4_address_router.sv
${NPC_HOME}/vsrc/riscv32/system/riscv32_axi4_error_target.sv
${NPC_HOME}/vsrc/riscv32/system/peripheral/riscv32_axi4_clint.sv
${NPC_HOME}/vsrc/riscv32/system/riscv32_npc_system.sv
${NPC_HOME}/vsrc/riscv32/system/riscv32_axi4_soc_width_converter.sv
${NPC_HOME}/vsrc/riscv32/system/riscv32_npc_axi.sv
