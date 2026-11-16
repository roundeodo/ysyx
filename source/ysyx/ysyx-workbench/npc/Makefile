.DEFAULT_GOAL := help

# ============================================================
# Project and build layout
# ============================================================

PROJECT ?= riscv
# 当前只维护 RV64 顺序核。容量参数保留为构建参数，方便 cachesim 与 RTL 比较；
# 前端采用RV32面试分支2026-09-24选定的配置；RV64性能与PPA需独立测量。
include configs/rv64-edge-ai.mk
NPC_SIM_TIMING_DEFINE := +define+YSYX_SIM_CPU_FREQ_MHZ=$(NPC_SIM_CPU_FREQ_MHZ)
ifeq ($(shell test "$(NPC_SIM_CPU_FREQ_MHZ)" -ge 100 -a "$(NPC_SIM_CPU_FREQ_MHZ)" -le 4000 2>/dev/null && echo yes),)
$(error NPC_SIM_CPU_FREQ_MHZ must be an integer in 100..4000)
endif

ifeq ($(filter $(NPC_DCACHE_ENABLE),0 1),)
$(error NPC_DCACHE_ENABLE must be 0 or 1)
endif
ifeq ($(filter $(NPC_SDRAM_NATIVE_READ_BURST),0 1),)
$(error NPC_SDRAM_NATIVE_READ_BURST must be 0 or 1)
endif

ifeq ($(filter $(NPC_ICACHE_REPLACEMENT_POLICY),0 13),)
$(error NPC_ICACHE_REPLACEMENT_POLICY must be 0 or 13)
endif
ifeq ($(NPC_ICACHE_WAY_COUNT),1)
ifneq ($(NPC_ICACHE_REPLACEMENT_POLICY),0)
$(error direct-mapped I-cache requires NPC_ICACHE_REPLACEMENT_POLICY=0)
endif
endif

SUPPORTED_NPC_CONFIGS := rv64-edge-ai
ifeq ($(filter $(NPC_CONFIG),$(SUPPORTED_NPC_CONFIGS)),)
$(error unsupported NPC_CONFIG=$(NPC_CONFIG); expected one of: $(SUPPORTED_NPC_CONFIGS))
endif
NPC_CONFIG_CXXFLAG := -DNPC_XLEN=64

NPC_CONFIG_DEFINE := +define+YSYX_ICACHE_CAPACITY_BYTES=$(NPC_ICACHE_CAPACITY_BYTES) \
	+define+YSYX_ICACHE_WAY_COUNT=$(NPC_ICACHE_WAY_COUNT) \
	+define+YSYX_ICACHE_LINE_BYTES=$(NPC_ICACHE_LINE_BYTES) \
	+define+YSYX_ICACHE_REPLACEMENT_POLICY=$(NPC_ICACHE_REPLACEMENT_POLICY) \
	+define+YSYX_DCACHE_ENABLE=$(NPC_DCACHE_ENABLE) \
	+define+YSYX_DCACHE_CAPACITY_BYTES=$(NPC_DCACHE_CAPACITY_BYTES) \
	+define+YSYX_DCACHE_WAY_COUNT=$(NPC_DCACHE_WAY_COUNT) \
	+define+YSYX_DCACHE_LINE_BYTES=$(NPC_DCACHE_LINE_BYTES) \
	+define+YSYX_BRANCH_HISTORY_ENTRY_COUNT=$(NPC_BRANCH_HISTORY_ENTRY_COUNT) \
	+define+YSYX_BRANCH_TARGET_ENTRY_COUNT=$(NPC_BRANCH_TARGET_ENTRY_COUNT) \
	+define+YSYX_BRANCH_TARGET_WAY_COUNT=$(NPC_BRANCH_TARGET_WAY_COUNT) \
	+define+YSYX_RETURN_STACK_ENTRY_COUNT=$(NPC_RETURN_STACK_ENTRY_COUNT) \
	+define+YSYX_SDRAM_NATIVE_READ_BURST=$(NPC_SDRAM_NATIVE_READ_BURST)

NPC_SLANG_DEFINE := -DYSYX_ICACHE_CAPACITY_BYTES=$(NPC_ICACHE_CAPACITY_BYTES) \
	-DYSYX_ICACHE_WAY_COUNT=$(NPC_ICACHE_WAY_COUNT) \
	-DYSYX_ICACHE_LINE_BYTES=$(NPC_ICACHE_LINE_BYTES) \
	-DYSYX_ICACHE_REPLACEMENT_POLICY=$(NPC_ICACHE_REPLACEMENT_POLICY) \
	-DYSYX_DCACHE_ENABLE=$(NPC_DCACHE_ENABLE) \
	-DYSYX_DCACHE_CAPACITY_BYTES=$(NPC_DCACHE_CAPACITY_BYTES) \
	-DYSYX_DCACHE_WAY_COUNT=$(NPC_DCACHE_WAY_COUNT) \
	-DYSYX_DCACHE_LINE_BYTES=$(NPC_DCACHE_LINE_BYTES) \
	-DYSYX_BRANCH_HISTORY_ENTRY_COUNT=$(NPC_BRANCH_HISTORY_ENTRY_COUNT) \
	-DYSYX_BRANCH_TARGET_ENTRY_COUNT=$(NPC_BRANCH_TARGET_ENTRY_COUNT) \
	-DYSYX_BRANCH_TARGET_WAY_COUNT=$(NPC_BRANCH_TARGET_WAY_COUNT) \
	-DYSYX_RETURN_STACK_ENTRY_COUNT=$(NPC_RETURN_STACK_ENTRY_COUNT) \
	-DYSYX_SDRAM_NATIVE_READ_BURST=$(NPC_SDRAM_NATIVE_READ_BURST)

NPC_TOP_MODULE := top
SOC_TOP_MODULE := ysyxSoCFull

DCACHE_BUILD_TAG := $(if $(filter 1,$(NPC_DCACHE_ENABLE)),dcache-$(NPC_DCACHE_CAPACITY_BYTES)b-way-$(NPC_DCACHE_WAY_COUNT)-line-$(NPC_DCACHE_LINE_BYTES)b,dcache-off)
PREDICTOR_BUILD_TAG := predictor-bht-$(NPC_BRANCH_HISTORY_ENTRY_COUNT)-btb-$(NPC_BRANCH_TARGET_ENTRY_COUNT)x$(NPC_BRANCH_TARGET_WAY_COUNT)-ras-$(NPC_RETURN_STACK_ENTRY_COUNT)
BUILD_DIR := $(abspath ./build/$(PROJECT)/$(NPC_CONFIG))/icache-$(NPC_ICACHE_CAPACITY_BYTES)b-way-$(NPC_ICACHE_WAY_COUNT)-line-$(NPC_ICACHE_LINE_BYTES)b-policy-$(NPC_ICACHE_REPLACEMENT_POLICY)/$(DCACHE_BUILD_TAG)/$(PREDICTOR_BUILD_TAG)/cpu-$(NPC_SIM_CPU_FREQ_MHZ)mhz
ifeq ($(NPC_SDRAM_NATIVE_READ_BURST),0)
BUILD_DIR := $(BUILD_DIR)/sdram-read-bl1
endif
NPC_OBJ_DIR     := $(BUILD_DIR)/obj_dir_npc
SOC_OBJ_DIR     := $(BUILD_DIR)/obj_dir_soc
NVBOARD_OBJ_DIR := $(BUILD_DIR)/obj_dir_nvboard
CONFIG_TEST_OBJ_DIR := $(BUILD_DIR)/obj_dir_config_test
IDU_TEST_OBJ_DIR    := $(BUILD_DIR)/obj_dir_idu_test
EXU_TEST_OBJ_DIR    := $(BUILD_DIR)/obj_dir_exu_test
LSU_TEST_OBJ_DIR    := $(BUILD_DIR)/obj_dir_lsu_test
PIPELINE_TEST_OBJ_DIR := $(BUILD_DIR)/obj_dir_pipeline_test
UNCACHED_TEST_OBJ_DIR := $(BUILD_DIR)/obj_dir_uncached_test
DCACHE_TEST_OBJ_DIR := $(BUILD_DIR)/obj_dir_dcache_test
CORE_MERGE_TEST_OBJ_DIR := $(BUILD_DIR)/obj_dir_core_merge_test
SOC_WIDTH_CONVERTER_TEST_OBJ_DIR := $(BUILD_DIR)/obj_dir_soc_width_converter_test
PRIVILEGED_TEST_OBJ_DIR := $(BUILD_DIR)/obj_dir_privileged_test
SDRAM_AXI_TEST_BUILD_DIR := $(abspath ./build/tests/sdram_axi)
SDRAM_AXI_TEST_OBJ_DIR   := $(SDRAM_AXI_TEST_BUILD_DIR)/obj_dir
AXI_DELAYER_TEST_BUILD_DIR := $(abspath ./build/tests/axi4_delayer)
AXI_DELAYER_TEST_OBJ_DIR   := $(AXI_DELAYER_TEST_BUILD_DIR)/obj_dir

NPC_SIM_BINARY     := $(BUILD_DIR)/$(NPC_TOP_MODULE)_sim
SOC_SIM_BINARY     := $(BUILD_DIR)/$(SOC_TOP_MODULE)_sim
NVBOARD_SIM_BINARY := $(BUILD_DIR)/$(SOC_TOP_MODULE)_nvboard
CONFIG_TEST_BINARY := $(BUILD_DIR)/config_elaboration_test
IDU_TEST_BINARY    := $(BUILD_DIR)/idu_decode_test
EXU_TEST_BINARY    := $(BUILD_DIR)/exu_alu_test
LSU_TEST_BINARY    := $(BUILD_DIR)/lsu_test
PIPELINE_TEST_BINARY := $(BUILD_DIR)/pipeline_control_test
UNCACHED_TEST_BINARY := $(BUILD_DIR)/uncached_axi4_test
DCACHE_TEST_BINARY := $(BUILD_DIR)/dcache_test
CORE_MERGE_TEST_BINARY := $(BUILD_DIR)/core_merge_test
SOC_WIDTH_CONVERTER_TEST_BINARY := $(BUILD_DIR)/soc_width_converter_test
PRIVILEGED_TEST_BINARY := $(BUILD_DIR)/privileged_test
SDRAM_AXI_TEST_BINARY  := $(SDRAM_AXI_TEST_BUILD_DIR)/sdram_axi_test
AXI_DELAYER_TEST_BINARY := $(AXI_DELAYER_TEST_BUILD_DIR)/axi4_delayer_test

IMG       ?=
FLASH_IMG ?=
ELF       ?=
REF       ?=
SIM_ARGS  ?= --batch

NEMU_DIR      := $(abspath ../nemu)
CPU_TESTS_DIR := $(abspath ../am-kernels/tests/cpu-tests)
MICROBENCH_DIR := $(abspath ../am-kernels/benchmarks/microbench)
RV64_NEMU_REF := $(NEMU_DIR)/build/riscv64-nemu-interpreter-so

CACHESIM_DIR         := $(abspath ./tools/cachesim)
CACHESIM_BUILD_DIR   := $(abspath ./build/tools/cachesim)
CACHESIM_SOURCE      := $(CACHESIM_DIR)/cachesim.cpp
CACHESIM_BINARY      := $(CACHESIM_BUILD_DIR)/cachesim
CACHESIM_TEST_SCRIPT := $(CACHESIM_DIR)/tests/test_cachesim.py
CACHESIM_CALIBRATION_TEST_SCRIPT := $(CACHESIM_DIR)/tests/test_calibration.py
CACHESIM_EXPLORE_SCRIPT := $(CACHESIM_DIR)/explore.py
ICACHE_CALIBRATION_SCRIPT := $(abspath ./scripts/calibrate_icache_penalty.py)

BRANCHSIM_DIR            := $(abspath ./tools/branchsim)
BRANCHSIM_BUILD_DIR      := $(abspath ./build/tools/branchsim)
BRANCHSIM_SOURCE         := $(BRANCHSIM_DIR)/branchsim.cpp
BRANCHSIM_BINARY         := $(BRANCHSIM_BUILD_DIR)/branchsim
BRANCHSIM_TEST_SCRIPT    := $(BRANCHSIM_DIR)/tests/test_branchsim.py
BRANCHSIM_EXPLORE_SCRIPT := $(BRANCHSIM_DIR)/explore.py

# ISA回归同样通过Flash启动，在完整SoC的SDRAM中执行。
# unalign要求硬件透明处理非对齐访问，与当前“产生misaligned异常”的架构契约冲突；
# 外设专用程序仍属于SoC外设回归，不混入ISA测试列表。
RV64_CPU_TESTS := \
	add add-longlong bit bubble-sort crc32 csr-trap div dummy fact fib goldbach \
	hello-str if-else leap-year load-store matrix-mul max mersenne min3 mov-c \
	movsx mul-longlong pascal prime quick-sort recursion select-sort shift \
	shuixianhua string sub-longlong sum switch to-lower-case wanshu

# ============================================================
# Source files
# ============================================================

INC_PATH ?=
INC_PATH += $(abspath ./include)

CAPSTONE_HOME ?= $(abspath ../nemu/tools/capstone/repo)
CAPSTONE_INC  ?= $(CAPSTONE_HOME)/include
CAPSTONE_LIB  ?= $(CAPSTONE_HOME)
INC_PATH      += $(CAPSTONE_INC)

RTL_DIR      := $(abspath ./vsrc/$(PROJECT))
RTL_FILELIST ?= $(RTL_DIR)/filelist/filelist.f

# Convert the filelist into Make dependencies. Verilator still reads the
# original filelist, including its comments and ordering.
RTL_DEPENDENCIES := $(shell sed \
	-e 's|$${NPC_HOME}|$(abspath .)|g' \
	-e '/^[[:space:]]*\/\//d' \
	-e '/^[[:space:]]*[+-]/d' \
	-e '/^[[:space:]]*$$/d' \
	$(RTL_FILELIST))

STA_RTL_FILELIST := $(RTL_DIR)/filelist/filelist_sta.f
STA_RTL_DEPENDENCIES := $(shell sed \
	-e 's|$${NPC_HOME}|$(abspath .)|g' \
	-e '/^[[:space:]]*\/\//d' \
	-e '/^[[:space:]]*[+-]/d' \
	-e '/^[[:space:]]*$$/d' \
	$(STA_RTL_FILELIST))

SOC_HOME             := $(abspath ../ysyxSoC)
SOC_PERIPHERAL_DIR   := $(SOC_HOME)/perip
SOC_GENERATED_TOP    := $(SOC_HOME)/build/ysyxSoCFull.v
SOC_VERILOG_SOURCES  := $(shell find $(SOC_PERIPHERAL_DIR) -type f -name "*.v" | sort)
SOC_VERILOG_SOURCES  += $(SOC_GENERATED_TOP)
SOC_RTL_INCLUDE_FLAGS := \
	-I$(SOC_PERIPHERAL_DIR)/uart16550/rtl \
	-I$(SOC_PERIPHERAL_DIR)/spi/rtl

SIM_CPP_SOURCES := $(shell find $(abspath ./csrc) -type f \
	\( -name "*.c" -o -name "*.cc" -o -name "*.cpp" \))

# ============================================================
# Verilator and C++ configuration
# ============================================================

VERILATOR ?= verilator
VERILATOR_FLAGS := \
	-MMD --build -cc -Wall -Wno-fatal \
	-O3 -j 2 -MAKEFLAGS "OPT_FAST=-O3 OPT_GLOBAL=-O3 OPT_SLOW=-O1" --x-assign fast --x-initial fast \
	--trace --autoflush \
	--timescale "1ns/1ns" --no-timing

CXX_INCLUDE_FLAGS := $(addprefix -I, $(INC_PATH))

# The same C++ simulator drives two RTL shells. These macros describe each
# shell's generated C++ class and reset polarity.
NPC_CXXFLAGS := $(CXX_INCLUDE_FLAGS) \
	$(NPC_CONFIG_CXXFLAG) \
	-DNPC_STANDALONE_SIM \
	-DTOP_CLASS=V$(NPC_TOP_MODULE) \
	-DTOP_DPI_CLASS=V$(NPC_TOP_MODULE)__Dpi \
	-DTOP_CLOCK=clk \
	-DTOP_RESET=rstn \
	-DTOP_RESET_ACTIVE_LEVEL=0

SOC_CXXFLAGS := $(CXX_INCLUDE_FLAGS) \
	$(NPC_CONFIG_CXXFLAG) \
	-DNPC_YSYXSOC_SIM \
	-DTOP_CLASS=V$(SOC_TOP_MODULE) \
	-DTOP_DPI_CLASS=V$(SOC_TOP_MODULE)__Dpi \
	-DTOP_CLOCK=clock \
	-DTOP_RESET=reset \
	-DTOP_RESET_ACTIVE_LEVEL=1

NVBOARD_CXXFLAGS := $(SOC_CXXFLAGS) -DCONFIG_NVBOARD

COMMON_LDFLAGS := \
	-L$(CAPSTONE_LIB) \
	-Wl,-rpath=$(CAPSTONE_LIB) \
	-lcapstone -ldl

CONFIG_TEST_SOURCES := \
	$(RTL_DIR)/common/riscv_config_pkg.sv \
	$(abspath ./tests/rtl/riscv_config_elaboration_tb.sv)

IDU_TEST_SOURCES := \
	$(RTL_DIR)/common/riscv_config_pkg.sv \
	$(RTL_DIR)/common/riscv_addr_map_pkg.sv \
	$(RTL_DIR)/common/riscv_pkg.sv \
	$(RTL_DIR)/core/decode/riscv_idu.sv \
	$(abspath ./tests/rtl/riscv_idu_decode_tb.sv)

EXU_TEST_SOURCES := \
	$(RTL_DIR)/common/riscv_config_pkg.sv \
	$(RTL_DIR)/common/riscv_addr_map_pkg.sv \
	$(RTL_DIR)/common/riscv_pkg.sv \
	$(RTL_DIR)/core/execute/riscv_alu.sv \
	$(RTL_DIR)/core/execute/riscv_branch_unit.sv \
	$(RTL_DIR)/core/execute/riscv_multiplier.sv \
	$(RTL_DIR)/core/execute/riscv_divider.sv \
	$(RTL_DIR)/core/execute/riscv_exu.sv \
	$(abspath ./tests/rtl/riscv_exu_alu_tb.sv)

LSU_TEST_SOURCES := \
	$(RTL_DIR)/common/riscv_config_pkg.sv \
	$(RTL_DIR)/common/riscv_addr_map_pkg.sv \
	$(RTL_DIR)/common/riscv_pkg.sv \
	$(RTL_DIR)/core/memory/riscv_lsu.sv \
	$(abspath ./tests/rtl/riscv_lsu_tb.sv)

PIPELINE_TEST_SOURCES := \
	$(RTL_DIR)/common/riscv_config_pkg.sv \
	$(RTL_DIR)/common/riscv_addr_map_pkg.sv \
	$(RTL_DIR)/common/riscv_pkg.sv \
	$(RTL_DIR)/core/execute/riscv_id_ex_reg.sv \
	$(RTL_DIR)/core/control/riscv_hazard_ctrl.sv \
	$(RTL_DIR)/core/writeback/riscv_completion_mux.sv \
	$(RTL_DIR)/core/writeback/riscv_wb_reg.sv \
	$(RTL_DIR)/core/writeback/riscv_commit.sv \
	$(RTL_DIR)/core/control/riscv_trap_ctrl.sv \
	$(RTL_DIR)/core/frontend/riscv_fetch_buffer.sv \
	$(RTL_DIR)/core/frontend/riscv_bht.sv \
	$(RTL_DIR)/core/frontend/riscv_btb.sv \
	$(RTL_DIR)/core/frontend/riscv_ras.sv \
	$(RTL_DIR)/core/frontend/riscv_branch_predictor.sv \
	$(RTL_DIR)/core/frontend/riscv_ifu.sv \
	$(abspath ./tests/rtl/riscv_pipeline_control_tb.sv)

UNCACHED_TEST_SOURCES := \
	$(RTL_DIR)/common/riscv_config_pkg.sv \
	$(RTL_DIR)/common/riscv_addr_map_pkg.sv \
	$(RTL_DIR)/common/riscv_axi4_pkg.sv \
	$(RTL_DIR)/common/riscv_pkg.sv \
	$(RTL_DIR)/core/memory/riscv_uncached_axi.sv \
	$(abspath ./tests/rtl/riscv_uncached_axi4_master_tb.sv)

DCACHE_TEST_SOURCES := \
	$(RTL_DIR)/common/riscv_config_pkg.sv \
	$(RTL_DIR)/common/riscv_addr_map_pkg.sv \
	$(RTL_DIR)/common/riscv_axi4_pkg.sv \
	$(RTL_DIR)/common/riscv_pkg.sv \
	$(RTL_DIR)/core/memory/riscv_dcache_tag_array.sv \
	$(RTL_DIR)/core/memory/riscv_dcache_data_array.sv \
	$(RTL_DIR)/core/memory/riscv_dcache_axi.sv \
	$(RTL_DIR)/core/memory/riscv_dcache_miss_unit.sv \
	$(RTL_DIR)/core/memory/riscv_dcache.sv \
	$(RTL_DIR)/core/control/riscv_fence_i_ctrl.sv \
	$(abspath ./tests/rtl/riscv_dcache_tb.sv)

CORE_MERGE_TEST_SOURCES := \
	$(RTL_DIR)/common/riscv_config_pkg.sv \
	$(RTL_DIR)/common/riscv_axi4_pkg.sv \
	$(RTL_DIR)/system/riscv_axi4_arbiter.sv \
	$(abspath ./tests/rtl/riscv_axi4_core_merge_tb.sv)

SOC_WIDTH_CONVERTER_TEST_SOURCES := \
	$(RTL_DIR)/common/riscv_config_pkg.sv \
	$(RTL_DIR)/common/riscv_addr_map_pkg.sv \
	$(RTL_DIR)/common/riscv_axi4_pkg.sv \
	$(RTL_DIR)/common/riscv_ysyx_soc_axi4_pkg.sv \
	$(RTL_DIR)/common/riscv_pkg.sv \
	$(RTL_DIR)/core/frontend/riscv_pma.sv \
	$(RTL_DIR)/system/riscv_axi4_soc_width_converter.sv \
	$(abspath ./tests/rtl/riscv_axi4_soc_width_converter_tb.sv)

PRIVILEGED_TEST_SOURCES := \
	$(RTL_DIR)/common/riscv_config_pkg.sv \
	$(RTL_DIR)/common/riscv_addr_map_pkg.sv \
	$(RTL_DIR)/common/riscv_pkg.sv \
	$(RTL_DIR)/core/writeback/riscv_pmu.sv \
	$(RTL_DIR)/core/writeback/riscv_csr_file.sv \
	$(RTL_DIR)/core/writeback/riscv_commit.sv \
	$(RTL_DIR)/core/control/riscv_trap_ctrl.sv \
	$(abspath ./tests/rtl/riscv_privileged_tb.sv)

SDRAM_AXI_TEST_SOURCES := \
	$(SOC_HOME)/perip/sdram/sdram_top_axi.v \
	$(SOC_HOME)/perip/sdram/core_sdram_axi4/sdram_axi.v \
	$(SOC_HOME)/perip/sdram/core_sdram_axi4/sdram_axi_pmem.v \
	$(SOC_HOME)/perip/sdram/core_sdram_axi4/sdram_axi_core.v \
	$(SOC_HOME)/perip/sdram/sdram.v \
	$(abspath ./tests/rtl/sdram_axi_transaction_classification_tb.sv)

AXI_DELAYER_TEST_SOURCES := \
	$(SOC_HOME)/perip/amba/axi4_delayer.v \
	$(abspath ./tests/rtl/axi4_delayer_tb.sv)

# ============================================================
# NVBoard integration
# ============================================================

NXDC_FILE           := constr/top.nxdc
NVBOARD_BIND_SOURCE := $(BUILD_DIR)/auto_bind.cpp

$(NVBOARD_BIND_SOURCE): $(NXDC_FILE) | $(BUILD_DIR)
	python3 $(NVBOARD_HOME)/scripts/auto_pin_bind.py $< $@

NVBOARD_CPP_SOURCES := $(SIM_CPP_SOURCES) $(NVBOARD_BIND_SOURCE)
include $(NVBOARD_HOME)/scripts/nvboard.mk

# ============================================================
# Simulation builds
# ============================================================

$(BUILD_DIR):
	mkdir -p $@

$(SDRAM_AXI_TEST_BUILD_DIR):
	mkdir -p $@

$(AXI_DELAYER_TEST_BUILD_DIR):
	mkdir -p $@

# Fast functional environment: CPU + local AXI models, reset PC 0x8000_0000.
# Accurate environment: CPU integrated into ysyxSoC and its peripherals.
$(SOC_SIM_BINARY): Makefile configs/rv64-edge-ai.mk $(wildcard $(RTL_DIR)/sim/*.svh) $(RTL_FILELIST) $(RTL_DEPENDENCIES) \
		$(SOC_VERILOG_SOURCES) $(SIM_CPP_SOURCES) | $(BUILD_DIR)
	$(call git_commit, "sim RTL") # DO NOT REMOVE THIS LINE!!!
	$(VERILATOR) $(VERILATOR_FLAGS) \
		$(NPC_CONFIG_DEFINE) $(NPC_SIM_TIMING_DEFINE) \
		$(SOC_RTL_INCLUDE_FLAGS) \
		--top-module $(SOC_TOP_MODULE) \
		-f $(RTL_FILELIST) \
		$(SOC_VERILOG_SOURCES) \
		$(SIM_CPP_SOURCES) \
		$(addprefix -CFLAGS ,$(SOC_CXXFLAGS)) \
		$(addprefix -LDFLAGS ,$(COMMON_LDFLAGS)) \
		--Mdir $(SOC_OBJ_DIR) \
		--exe \
		-o $(SOC_SIM_BINARY)

$(NVBOARD_SIM_BINARY): $(wildcard $(RTL_DIR)/sim/*.svh) $(RTL_FILELIST) $(RTL_DEPENDENCIES) \
		$(SOC_VERILOG_SOURCES) $(NVBOARD_CPP_SOURCES) $(NVBOARD_ARCHIVE) | $(BUILD_DIR)
	$(call git_commit, "sim nvboard") # DO NOT REMOVE THIS LINE!!!
	$(VERILATOR) $(VERILATOR_FLAGS) \
		$(NPC_CONFIG_DEFINE) $(NPC_SIM_TIMING_DEFINE) \
		$(SOC_RTL_INCLUDE_FLAGS) \
		--top-module $(SOC_TOP_MODULE) \
		-f $(RTL_FILELIST) \
		$(SOC_VERILOG_SOURCES) \
		$(NVBOARD_CPP_SOURCES) \
		$(NVBOARD_ARCHIVE) \
		$(addprefix -CFLAGS ,$(NVBOARD_CXXFLAGS)) \
		$(addprefix -LDFLAGS ,$(COMMON_LDFLAGS) $(LDFLAGS)) \
		--Mdir $(NVBOARD_OBJ_DIR) \
		--exe \
		-o $(NVBOARD_SIM_BINARY)

$(CONFIG_TEST_BINARY): $(CONFIG_TEST_SOURCES) | $(BUILD_DIR)
	$(VERILATOR) --binary --timing --assert -Wall -Wno-fatal -Wno-UNUSEDPARAM \
		$(NPC_CONFIG_DEFINE) \
		--top-module riscv_config_elaboration_tb \
		$(CONFIG_TEST_SOURCES) \
		--Mdir $(CONFIG_TEST_OBJ_DIR) \
		-o $(CONFIG_TEST_BINARY)

$(IDU_TEST_BINARY): $(IDU_TEST_SOURCES) | $(BUILD_DIR)
	$(VERILATOR) --binary --timing --assert -Wall -Wno-fatal -Wno-UNUSEDPARAM \
		-Wno-UNUSEDSIGNAL \
		$(NPC_CONFIG_DEFINE) \
		--top-module riscv_idu_decode_tb \
		$(IDU_TEST_SOURCES) \
		--Mdir $(IDU_TEST_OBJ_DIR) \
		-o $(IDU_TEST_BINARY)

$(EXU_TEST_BINARY): $(EXU_TEST_SOURCES) | $(BUILD_DIR)
	$(VERILATOR) --binary --timing --assert -Wall -Wno-fatal -Wno-UNUSEDPARAM \
		-Wno-UNUSEDSIGNAL \
		$(NPC_CONFIG_DEFINE) \
		--top-module riscv_exu_alu_tb \
		$(EXU_TEST_SOURCES) \
		--Mdir $(EXU_TEST_OBJ_DIR) \
		-o $(EXU_TEST_BINARY)

$(LSU_TEST_BINARY): $(LSU_TEST_SOURCES) | $(BUILD_DIR)
	$(VERILATOR) --binary --timing --assert -Wall -Wno-fatal -Wno-UNUSEDPARAM \
		-Wno-UNUSEDSIGNAL \
		$(NPC_CONFIG_DEFINE) \
		--top-module riscv_lsu_tb \
		$(LSU_TEST_SOURCES) \
		--Mdir $(LSU_TEST_OBJ_DIR) \
		-o $(LSU_TEST_BINARY)

$(PIPELINE_TEST_BINARY): $(PIPELINE_TEST_SOURCES) | $(BUILD_DIR)
	$(VERILATOR) --binary --timing --assert -Wall -Wno-fatal -Wno-UNUSEDPARAM \
		-Wno-UNUSEDSIGNAL \
		$(NPC_CONFIG_DEFINE) \
		--top-module riscv_pipeline_control_tb \
		$(PIPELINE_TEST_SOURCES) \
		--Mdir $(PIPELINE_TEST_OBJ_DIR) \
		-o $(PIPELINE_TEST_BINARY)

$(UNCACHED_TEST_BINARY): $(UNCACHED_TEST_SOURCES) | $(BUILD_DIR)
	$(VERILATOR) --binary --timing --assert -Wall -Wno-fatal -Wno-UNUSEDPARAM \
		-Wno-UNUSEDSIGNAL \
		$(NPC_CONFIG_DEFINE) \
		--top-module riscv_uncached_axi4_master_tb \
		$(UNCACHED_TEST_SOURCES) \
		--Mdir $(UNCACHED_TEST_OBJ_DIR) \
		-o $(UNCACHED_TEST_BINARY)

$(DCACHE_TEST_BINARY): $(DCACHE_TEST_SOURCES) | $(BUILD_DIR)
	$(VERILATOR) --binary --timing --assert -Wall -Wno-fatal -Wno-UNUSEDPARAM \
		-Wno-UNUSEDSIGNAL \
		$(NPC_CONFIG_DEFINE) \
		--top-module riscv_dcache_tb \
		$(DCACHE_TEST_SOURCES) \
		--Mdir $(DCACHE_TEST_OBJ_DIR) \
		-o $(DCACHE_TEST_BINARY)

$(CORE_MERGE_TEST_BINARY): $(CORE_MERGE_TEST_SOURCES) | $(BUILD_DIR)
	$(VERILATOR) --binary --timing --assert -Wall -Wno-fatal -Wno-UNUSEDPARAM \
		-Wno-UNUSEDSIGNAL \
		$(NPC_CONFIG_DEFINE) \
		--top-module riscv_axi4_core_merge_tb \
		$(CORE_MERGE_TEST_SOURCES) \
		--Mdir $(CORE_MERGE_TEST_OBJ_DIR) \
		-o $(CORE_MERGE_TEST_BINARY)

$(SOC_WIDTH_CONVERTER_TEST_BINARY): $(SOC_WIDTH_CONVERTER_TEST_SOURCES) | $(BUILD_DIR)
	$(VERILATOR) --binary --timing --assert -Wall -Wno-fatal -Wno-UNUSEDPARAM \
		-Wno-UNUSEDSIGNAL \
		$(NPC_CONFIG_DEFINE) \
		--top-module riscv_axi4_soc_width_converter_tb \
		$(SOC_WIDTH_CONVERTER_TEST_SOURCES) \
		--Mdir $(SOC_WIDTH_CONVERTER_TEST_OBJ_DIR) \
		-o $(SOC_WIDTH_CONVERTER_TEST_BINARY)

$(PRIVILEGED_TEST_BINARY): $(PRIVILEGED_TEST_SOURCES) | $(BUILD_DIR)
	$(VERILATOR) --binary --timing --assert -Wall -Wno-fatal -Wno-UNUSEDPARAM \
		-Wno-UNUSEDSIGNAL \
		$(NPC_CONFIG_DEFINE) \
		--top-module riscv_privileged_tb \
		$(PRIVILEGED_TEST_SOURCES) \
		--Mdir $(PRIVILEGED_TEST_OBJ_DIR) \
		-o $(PRIVILEGED_TEST_BINARY)

$(SDRAM_AXI_TEST_BINARY): $(SDRAM_AXI_TEST_SOURCES) | $(SDRAM_AXI_TEST_BUILD_DIR)
	$(VERILATOR) --binary --timing --assert -Wall -Wno-fatal \
		-Wno-DECLFILENAME -Wno-PINCONNECTEMPTY -Wno-UNUSEDSIGNAL \
		--top-module sdram_axi_transaction_classification_tb \
		$(SDRAM_AXI_TEST_SOURCES) \
		--Mdir $(SDRAM_AXI_TEST_OBJ_DIR) \
		-o $(SDRAM_AXI_TEST_BINARY)

$(AXI_DELAYER_TEST_BINARY): $(AXI_DELAYER_TEST_SOURCES) | $(AXI_DELAYER_TEST_BUILD_DIR)
	$(VERILATOR) --binary --timing --assert -Wall -Wno-fatal \
		-Wno-BLKSEQ -Wno-TIMESCALEMOD -Wno-UNUSEDSIGNAL \
		--top-module axi4_delayer_tb \
		$(AXI_DELAYER_TEST_SOURCES) \
		--Mdir $(AXI_DELAYER_TEST_OBJ_DIR) \
		-o $(AXI_DELAYER_TEST_BINARY)

.PHONY: build-npc build-soc test-config test-configs test-idu test-idu-configs test-exu test-exu-configs test-lsu test-lsu-configs test-pipeline test-pipeline-configs test-uncached test-uncached-configs test-dcache test-dcache-configs test-core-merge test-core-merge-configs test-soc-width-converter test-sdram-axi test-axi-delayer test-privileged test-privileged-configs
build-npc: build-soc
build-soc: $(SOC_SIM_BINARY)
test-config: $(CONFIG_TEST_BINARY)
	$(CONFIG_TEST_BINARY)

.PHONY: test-icache test-icache-replacement
FRONTEND_TEST_OUTPUT ?= $(BUILD_DIR)/frontend-tests
test-icache:
	python3 scripts/test_icache.py --test cache --output "$(FRONTEND_TEST_OUTPUT)" $(NPC_CONFIG_DEFINE)

test-icache-replacement:
	python3 scripts/test_icache.py --test replacement --output "$(FRONTEND_TEST_OUTPUT)" $(NPC_CONFIG_DEFINE)

.PHONY: test-bypass test-precise-exception test-cache-recovery
test-bypass:
	python3 scripts/test_bypass.py --output "$(BUILD_DIR)/bypass-tests" $(NPC_CONFIG_DEFINE)

test-precise-exception:
	python3 tests/exception/run_precise.py --output "$(BUILD_DIR)/precise-exception" $(NPC_CONFIG_DEFINE)

test-cache-recovery:
	python3 scripts/test_cache_recovery.py --test core --output "$(BUILD_DIR)/cache-recovery" $(NPC_CONFIG_DEFINE)

test-configs:
	$(MAKE) test-config PROJECT=$(PROJECT) NPC_CONFIG=$(NPC_CONFIG)

test-idu: $(IDU_TEST_BINARY)
	$(IDU_TEST_BINARY)

test-idu-configs:
	$(MAKE) test-idu PROJECT=$(PROJECT) NPC_CONFIG=$(NPC_CONFIG)

test-exu: $(EXU_TEST_BINARY)
	$(EXU_TEST_BINARY)

test-exu-configs:
	$(MAKE) test-exu PROJECT=$(PROJECT) NPC_CONFIG=$(NPC_CONFIG)

test-lsu: $(LSU_TEST_BINARY)
	$(LSU_TEST_BINARY)

test-lsu-configs:
	$(MAKE) test-lsu PROJECT=$(PROJECT) NPC_CONFIG=$(NPC_CONFIG)

test-pipeline: $(PIPELINE_TEST_BINARY)
	$(PIPELINE_TEST_BINARY)

test-pipeline-configs:
	$(MAKE) test-pipeline PROJECT=$(PROJECT) NPC_CONFIG=$(NPC_CONFIG)

.PHONY: formal-pipeline
formal-pipeline:
	sby -f tests/formal/riscv_pipeline_control.sby

test-uncached: $(UNCACHED_TEST_BINARY)
	$(UNCACHED_TEST_BINARY)

test-uncached-configs:
	$(MAKE) test-uncached PROJECT=$(PROJECT) NPC_CONFIG=$(NPC_CONFIG)

test-dcache: $(DCACHE_TEST_BINARY)
	$(DCACHE_TEST_BINARY)

test-dcache-configs:
	$(MAKE) test-dcache PROJECT=$(PROJECT) NPC_CONFIG=$(NPC_CONFIG)

test-core-merge: $(CORE_MERGE_TEST_BINARY)
	$(CORE_MERGE_TEST_BINARY)

test-core-merge-configs:
	$(MAKE) test-core-merge PROJECT=$(PROJECT) NPC_CONFIG=$(NPC_CONFIG)

test-soc-width-converter: $(SOC_WIDTH_CONVERTER_TEST_BINARY)
	$(SOC_WIDTH_CONVERTER_TEST_BINARY)

test-sdram-axi: $(SDRAM_AXI_TEST_BINARY)
	$(SDRAM_AXI_TEST_BINARY)

test-axi-delayer: $(AXI_DELAYER_TEST_BINARY)
	$(AXI_DELAYER_TEST_BINARY)

test-privileged: $(PRIVILEGED_TEST_BINARY)
	$(PRIVILEGED_TEST_BINARY)

test-privileged-configs:
	$(MAKE) test-privileged PROJECT=$(PROJECT) NPC_CONFIG=$(NPC_CONFIG)

# ============================================================
# RV64 functional regression
# ============================================================

.PHONY: nemu-ref-rv64 regression-rv64-isa regression-rv64

nemu-ref-rv64:
	$(MAKE) -C $(NEMU_DIR) riscv64-ref_defconfig
	$(MAKE) -C $(NEMU_DIR)

regression-rv64-isa:
	$(MAKE) nemu-ref-rv64 PROJECT=$(PROJECT)
	$(MAKE) -C $(CPU_TESTS_DIR) \
		ARCH=riscv64-npc \
		NPC_CONFIG=$(NPC_CONFIG) \
		NPC_RUN_TARGET=sim-difftest \
		REF=$(RV64_NEMU_REF) \
		ALL="$(RV64_CPU_TESTS)" \
		run

# 定向测试先定位模块边界，最后再运行完整ISA DiffTest。
regression-rv64:
	$(MAKE) test-bypass PROJECT=$(PROJECT)
	$(MAKE) test-icache-replacement PROJECT=$(PROJECT)
	$(MAKE) test-precise-exception PROJECT=$(PROJECT)
	$(MAKE) test-cache-recovery PROJECT=$(PROJECT)
	$(MAKE) lint-configs PROJECT=$(PROJECT)
	$(MAKE) build-npc PROJECT=$(PROJECT) NPC_CONFIG=$(NPC_CONFIG)
	$(MAKE) regression-rv64-isa PROJECT=$(PROJECT)

# ============================================================
# Simulation entry points
# ============================================================

.PHONY: sim sim-npc sim-soc sim-am sim-image

# All software simulation uses calibrated ysyxSoC. Old target names are aliases.
sim sim-npc sim-am sim-image: sim-soc

sim-soc: $(SOC_SIM_BINARY)
	@test -n "$(strip $(FLASH_IMG))" || (echo "FLASH_IMG is required: build ARCH=riscv64-npc image"; exit 1)
	@test -z "$(strip $(IMG))" || (echo "Use FLASH_IMG with the SoC Flash/SDRAM image, not a flat IMG"; exit 1)
	$(SOC_SIM_BINARY) $(SIM_ARGS) --flash $(FLASH_IMG)

.PHONY: sim-itrace sim-mtrace sim-ftrace sim-trace sim-difftest sim-wave sim-debug
sim-itrace: SIM_ARGS += --itrace
sim-mtrace: SIM_ARGS += --mtrace
sim-ftrace: SIM_ARGS += --ftrace --elf $(ELF)
sim-trace sim-debug: SIM_ARGS += --itrace --mtrace
sim-wave sim-debug: SIM_ARGS += --trace
sim-difftest: SIM_ARGS += --diff $(REF)
sim-itrace sim-mtrace sim-ftrace sim-trace sim-difftest sim-wave sim-debug: sim-soc

.PHONY: nvboard
nvboard: $(NVBOARD_SIM_BINARY)
	@test -n "$(strip $(IMG)$(FLASH_IMG))" || \
		(echo "IMG or FLASH_IMG is required"; exit 1)
	$(NVBOARD_SIM_BINARY) --nvboard \
		$(if $(FLASH_IMG),--flash $(FLASH_IMG)) \
		$(IMG)

# ============================================================
# I-cache metadata simulation and design-space exploration
# ============================================================

CACHE_TRACE_ARCH             ?= riscv64-nemu
CACHE_TRACE_ISA              = riscv64
CACHE_TRACE_IMAGE            ?= $(CPU_TESTS_DIR)/build/bubble-sort-$(CACHE_TRACE_ISA)-npc.bin
CACHE_TRACE_FILE             ?= $(abspath ./result/cache/$(CACHE_TRACE_ISA)_nemu_pc_trace.bin)
CACHE_TRACE_IMAGE_PATH       = $(abspath $(CACHE_TRACE_IMAGE))
CACHE_TRACE_PATH             = $(abspath $(CACHE_TRACE_FILE))
CACHE_CAPACITY_BYTES         ?= $(NPC_ICACHE_CAPACITY_BYTES)
CACHE_LINE_BYTES             ?= $(NPC_ICACHE_LINE_BYTES)
CACHE_WAYS                   ?= $(NPC_ICACHE_WAY_COUNT)
# 当前RTL在命中时从lookup握手到响应握手需要1周期。
CACHE_HIT_TIME_CYCLES        ?= 1
# RV64 memory AXI每个beat为8字节。不同时间模型的AMAT/TMT不能直接混入同一组结论。
CACHE_REFILL_MODEL           ?= burst
CACHE_REFILL_BEAT_BYTES      ?= 8
# a/b/c/d默认各取1周期，只用于比较独立事务和burst的结构差异。实际周期结论必须用
# RTL PMU测得的critical-response与complete-refill延迟校准这四项参数。
CACHE_READ_ADDRESS_CYCLES    ?= 1
CACHE_MEMORY_COMMAND_CYCLES  ?= 1
CACHE_FIRST_DATA_CYCLES      ?= 1
CACHE_RESPONSE_BEAT_CYCLES   ?= 1
# fixed模型默认值只用于工具自测；架构结论必须使用RTL PMU校准值。
CACHE_CRITICAL_RESPONSE_PENALTY_CYCLES ?= 162.405
CACHE_COMPLETE_REFILL_PENALTY_CYCLES   ?= 286.283
CACHE_CRITICAL_RESPONSE_PENALTY_BY_LINE_SIZE ?=
CACHE_COMPLETE_REFILL_PENALTY_BY_LINE_SIZE   ?=
CACHE_PENALTY_CALIBRATION_FILE               ?=
CACHE_FIXED_PENALTY_ARGUMENTS = \
	$(if $(strip $(CACHE_CRITICAL_RESPONSE_PENALTY_BY_LINE_SIZE)),--critical-response-penalty-by-line-size $(CACHE_CRITICAL_RESPONSE_PENALTY_BY_LINE_SIZE)) \
	$(if $(strip $(CACHE_COMPLETE_REFILL_PENALTY_BY_LINE_SIZE)),--complete-refill-penalty-by-line-size $(CACHE_COMPLETE_REFILL_PENALTY_BY_LINE_SIZE)) \
	$(if $(strip $(CACHE_PENALTY_CALIBRATION_FILE)),--penalty-calibration-csv $(abspath $(CACHE_PENALTY_CALIBRATION_FILE)))
CACHE_SCAN_CAPACITIES        ?= 64,128,256,512,1024,2048,4096
CACHE_SCAN_LINE_SIZES        ?= 4,8,16,32,64
CACHE_SCAN_WAYS              ?= 1,2
CACHE_SCAN_JOBS              ?= 4
CACHE_RANKING_METRIC         ?= blocking-tmt
CACHE_SCAN_OUTPUT            ?= $(abspath ./result/cache/cachesim_$(CACHE_TRACE_ISA)_$(CACHE_REFILL_MODEL)_exploration.csv)
ICACHE_CALIBRATION_LINE_SIZES     ?= 8,16,32,64
ICACHE_CALIBRATION_SCALE          ?= test
ICACHE_CALIBRATION_ARCH           ?= riscv64-npc
ICACHE_CALIBRATION_CAPACITY_BYTES ?= $(NPC_ICACHE_CAPACITY_BYTES)
ICACHE_CALIBRATION_WAY_COUNT      ?= $(NPC_ICACHE_WAY_COUNT)
ICACHE_CALIBRATION_MEMORY_NAME     = soc-sdram
ICACHE_CALIBRATION_OUTPUT         ?= $(abspath ./result/cache/rtl_icache_penalty_rv64_$(ICACHE_CALIBRATION_MEMORY_NAME)_$(ICACHE_CALIBRATION_SCALE).csv)

$(CACHESIM_BUILD_DIR):
	mkdir -p $@

$(CACHESIM_BINARY): $(CACHESIM_SOURCE) | $(CACHESIM_BUILD_DIR)
	$(CXX) -std=c++17 -O3 -Wall -Wextra -Wpedantic -Werror $< -o $@

.PHONY: cachesim-build cachesim-test cachesim-trace cachesim-run cachesim-explore \
	cachesim-explore-baseline cachesim-explore-transport \
	icache-calibrate-penalty cachesim-explore-calibrated
cachesim-build: $(CACHESIM_BINARY)

cachesim-test: $(CACHESIM_BINARY)
	python3 $(CACHESIM_TEST_SCRIPT) $(CACHESIM_BINARY)
	python3 $(CACHESIM_CALIBRATION_TEST_SCRIPT)

# NEMU只负责产生架构执行PC序列；cachesim不依赖NEMU内部数据结构。
# 该入口会切换NEMU的活动.config，后续构建DiffTest reference时相应的nemu-ref目标会
# 再切换回共享库配置。
cachesim-trace:
	@test "$(CACHE_TRACE_ARCH)" = "riscv64-nemu" || \
		(echo "CACHE_TRACE_ARCH must be riscv64-nemu"; exit 1)
	@test -f "$(CACHE_TRACE_IMAGE_PATH)" || \
		(echo "trace image not found: $(CACHE_TRACE_IMAGE_PATH)"; exit 1)
	mkdir -p $(dir $(CACHE_TRACE_PATH))
	$(MAKE) -C $(NEMU_DIR) riscv64-cachesim_defconfig
	$(MAKE) -C $(NEMU_DIR) run \
		ARGS="--cachesim-trace=$(CACHE_TRACE_PATH) -b" \
		IMG=$(CACHE_TRACE_IMAGE_PATH)
	@echo "NEMU compact PC trace: $(CACHE_TRACE_PATH)"

cachesim-run: $(CACHESIM_BINARY)
	@test -f "$(CACHE_TRACE_PATH)" || \
		(echo "trace file not found: $(CACHE_TRACE_PATH)"; exit 1)
	$(CACHESIM_BINARY) \
		--trace $(CACHE_TRACE_PATH) \
		--capacity-bytes $(CACHE_CAPACITY_BYTES) \
		--line-bytes $(CACHE_LINE_BYTES) \
		--ways $(CACHE_WAYS) \
		--hit-time-cycles $(CACHE_HIT_TIME_CYCLES) \
		--refill-model $(CACHE_REFILL_MODEL) \
		--refill-beat-bytes $(CACHE_REFILL_BEAT_BYTES) \
		--read-address-cycles $(CACHE_READ_ADDRESS_CYCLES) \
		--memory-command-cycles $(CACHE_MEMORY_COMMAND_CYCLES) \
		--first-data-cycles $(CACHE_FIRST_DATA_CYCLES) \
		--response-beat-cycles $(CACHE_RESPONSE_BEAT_CYCLES) \
		--critical-response-penalty-cycles $(CACHE_CRITICAL_RESPONSE_PENALTY_CYCLES) \
		--complete-refill-penalty-cycles $(CACHE_COMPLETE_REFILL_PENALTY_CYCLES)

cachesim-explore: $(CACHESIM_BINARY)
	@test -f "$(CACHE_TRACE_PATH)" || \
		(echo "trace file not found: $(CACHE_TRACE_PATH)"; exit 1)
	python3 $(CACHESIM_EXPLORE_SCRIPT) \
		--binary $(CACHESIM_BINARY) \
		--trace $(CACHE_TRACE_PATH) \
		--capacities $(CACHE_SCAN_CAPACITIES) \
		--line-sizes $(CACHE_SCAN_LINE_SIZES) \
		--ways $(CACHE_SCAN_WAYS) \
		--hit-time-cycles $(CACHE_HIT_TIME_CYCLES) \
		--refill-model $(CACHE_REFILL_MODEL) \
		--refill-beat-bytes $(CACHE_REFILL_BEAT_BYTES) \
		--read-address-cycles $(CACHE_READ_ADDRESS_CYCLES) \
		--memory-command-cycles $(CACHE_MEMORY_COMMAND_CYCLES) \
		--first-data-cycles $(CACHE_FIRST_DATA_CYCLES) \
		--response-beat-cycles $(CACHE_RESPONSE_BEAT_CYCLES) \
		--critical-response-penalty-cycles $(CACHE_CRITICAL_RESPONSE_PENALTY_CYCLES) \
		--complete-refill-penalty-cycles $(CACHE_COMPLETE_REFILL_PENALTY_CYCLES) \
		$(CACHE_FIXED_PENALTY_ARGUMENTS) \
		--jobs $(CACHE_SCAN_JOBS) \
		--ranking-metric $(CACHE_RANKING_METRIC) \
		--output $(CACHE_SCAN_OUTPUT)

cachesim-explore-baseline:
	$(MAKE) cachesim-explore CACHE_REFILL_MODEL=fixed \
		CACHE_SCAN_OUTPUT=$(abspath ./result/cache/cachesim_$(CACHE_TRACE_ISA)_fixed_exploration.csv)

cachesim-explore-transport:
	$(MAKE) cachesim-explore CACHE_REFILL_MODEL=independent \
		CACHE_SCAN_OUTPUT=$(abspath ./result/cache/cachesim_$(CACHE_TRACE_ISA)_independent_exploration.csv)
	$(MAKE) cachesim-explore CACHE_REFILL_MODEL=burst \
		CACHE_SCAN_OUTPUT=$(abspath ./result/cache/cachesim_$(CACHE_TRACE_ISA)_burst_exploration.csv)

# 在同一校准SoC环境中逐项重编译并运行MicroBench，从RTL PMU提取critical-word
# 响应代价和整行refill占用。存储目标、容量和路数显式写入CSV，禁止跨环境混用代价。
icache-calibrate-penalty:
	python3 $(ICACHE_CALIBRATION_SCRIPT) \
		--npc-dir $(abspath .) \
		--line-sizes $(ICACHE_CALIBRATION_LINE_SIZES) \
		--cache-capacity-bytes $(ICACHE_CALIBRATION_CAPACITY_BYTES) \
		--cache-way-count $(ICACHE_CALIBRATION_WAY_COUNT) \
		--benchmark-arch $(ICACHE_CALIBRATION_ARCH) \
		--scale $(ICACHE_CALIBRATION_SCALE) \
		--output $(ICACHE_CALIBRATION_OUTPUT)

# 用RTL校准出的逐line缺失代价运行metadata-only cachesim。这里固定使用fixed模型，
# 因为CSV中的周期已经包含当前总线、延迟模块、SDRAM控制器和refill实现的综合效果。
cachesim-explore-calibrated:
	@test -f "$(ICACHE_CALIBRATION_OUTPUT)" || \
		(echo "I-cache calibration file not found: $(ICACHE_CALIBRATION_OUTPUT)"; exit 1)
	$(MAKE) cachesim-explore \
		CACHE_REFILL_MODEL=fixed \
		CACHE_PENALTY_CALIBRATION_FILE=$(ICACHE_CALIBRATION_OUTPUT) \
		CACHE_SCAN_OUTPUT=$(abspath ./result/cache/cachesim_$(CACHE_TRACE_ISA)_rtl_calibrated_$(ICACHE_CALIBRATION_SCALE).csv)

# ============================================================
# D-cache metadata simulation and design-space exploration
# ============================================================

# 数据trace记录的是已执行load/store的普通内存地址，不含取指和MMIO。模型采用
# write-back、write-allocate和精确LRU；burst模型按整行读入和脏行整行写回计时。
DCACHE_TRACE_ARCH       ?= riscv64-nemu
DCACHE_TRACE_ISA        = riscv64
DCACHE_TRACE_SCALE      ?= test
DCACHE_TRACE_IMAGE      ?= $(MICROBENCH_DIR)/build/microbench-$(DCACHE_TRACE_ARCH).bin
DCACHE_TRACE_FILE       ?= $(abspath ./result/cache/$(DCACHE_TRACE_ISA)_microbench_$(DCACHE_TRACE_SCALE)_data_trace.bin)
DCACHE_TRACE_IMAGE_PATH = $(abspath $(DCACHE_TRACE_IMAGE))
DCACHE_TRACE_PATH       = $(abspath $(DCACHE_TRACE_FILE))
DCACHE_CAPACITY_BYTES   ?= 1024
DCACHE_LINE_BYTES       ?= 32
DCACHE_WAYS             ?= 2
DCACHE_HIT_TIME_CYCLES  ?= 1
DCACHE_REFILL_MODEL     ?= burst
DCACHE_REFILL_BEAT_BYTES ?= 8
DCACHE_READ_ADDRESS_CYCLES   ?= 1
DCACHE_MEMORY_COMMAND_CYCLES ?= 1
DCACHE_FIRST_DATA_CYCLES     ?= 1
DCACHE_RESPONSE_BEAT_CYCLES  ?= 1
DCACHE_WRITE_ADDRESS_CYCLES  ?= 1
DCACHE_WRITE_DATA_BEAT_CYCLES ?= 1
DCACHE_WRITE_RESPONSE_CYCLES ?= 1
DCACHE_FIXED_CRITICAL_RESPONSE_PENALTY_CYCLES ?= 0
DCACHE_FIXED_COMPLETE_REFILL_PENALTY_CYCLES   ?= 0
DCACHE_FIXED_DIRTY_WRITEBACK_PENALTY_CYCLES   ?= 0
DCACHE_SCAN_CAPACITIES ?= 256,512,1024,2048,4096,8192
DCACHE_SCAN_LINE_SIZES ?= 8,16,32,64
DCACHE_SCAN_WAYS       ?= 1,2,4
DCACHE_SCAN_JOBS       ?= 4
DCACHE_SCAN_OUTPUT     ?= $(abspath ./result/cache/dcachesim_$(DCACHE_TRACE_ISA)_$(DCACHE_TRACE_SCALE)_$(DCACHE_REFILL_MODEL)_exploration.csv)

DCACHE_MODEL_ARGUMENTS = \
	--hit-time-cycles $(DCACHE_HIT_TIME_CYCLES) \
	--refill-model $(DCACHE_REFILL_MODEL) \
	--refill-beat-bytes $(DCACHE_REFILL_BEAT_BYTES) \
	--critical-response-penalty-cycles $(DCACHE_FIXED_CRITICAL_RESPONSE_PENALTY_CYCLES) \
	--complete-refill-penalty-cycles $(DCACHE_FIXED_COMPLETE_REFILL_PENALTY_CYCLES) \
	--dirty-writeback-penalty-cycles $(DCACHE_FIXED_DIRTY_WRITEBACK_PENALTY_CYCLES) \
	--read-address-cycles $(DCACHE_READ_ADDRESS_CYCLES) \
	--memory-command-cycles $(DCACHE_MEMORY_COMMAND_CYCLES) \
	--first-data-cycles $(DCACHE_FIRST_DATA_CYCLES) \
	--response-beat-cycles $(DCACHE_RESPONSE_BEAT_CYCLES) \
	--write-address-cycles $(DCACHE_WRITE_ADDRESS_CYCLES) \
	--write-data-beat-cycles $(DCACHE_WRITE_DATA_BEAT_CYCLES) \
	--write-response-cycles $(DCACHE_WRITE_RESPONSE_CYCLES)

.PHONY: dcachesim-trace dcachesim-run dcachesim-explore
dcachesim-trace:
	@test "$(DCACHE_TRACE_ARCH)" = "riscv64-nemu" || \
		(echo "DCACHE_TRACE_ARCH must be riscv64-nemu"; exit 1)
	$(MAKE) -C $(NEMU_DIR) riscv64-cachesim_defconfig
	$(MAKE) -C $(MICROBENCH_DIR) ARCH=$(DCACHE_TRACE_ARCH) clean
	$(MAKE) -C $(MICROBENCH_DIR) \
		ARCH=$(DCACHE_TRACE_ARCH) mainargs=$(DCACHE_TRACE_SCALE) insert-arg
	mkdir -p $(dir $(DCACHE_TRACE_PATH))
	$(MAKE) -C $(NEMU_DIR) run \
		ARGS="--cachesim-data-trace=$(DCACHE_TRACE_PATH) -b" \
		IMG=$(DCACHE_TRACE_IMAGE_PATH)
	@echo "NEMU compact data trace: $(DCACHE_TRACE_PATH)"

dcachesim-run: $(CACHESIM_BINARY)
	@test -f "$(DCACHE_TRACE_PATH)" || \
		(echo "data trace file not found: $(DCACHE_TRACE_PATH)"; exit 1)
	$(CACHESIM_BINARY) \
		--trace $(DCACHE_TRACE_PATH) \
		--capacity-bytes $(DCACHE_CAPACITY_BYTES) \
		--line-bytes $(DCACHE_LINE_BYTES) \
		--ways $(DCACHE_WAYS) \
		$(DCACHE_MODEL_ARGUMENTS)

dcachesim-explore: $(CACHESIM_BINARY)
	@test -f "$(DCACHE_TRACE_PATH)" || \
		(echo "data trace file not found: $(DCACHE_TRACE_PATH)"; exit 1)
	python3 $(CACHESIM_EXPLORE_SCRIPT) \
		--binary $(CACHESIM_BINARY) \
		--trace $(DCACHE_TRACE_PATH) \
		--capacities $(DCACHE_SCAN_CAPACITIES) \
		--line-sizes $(DCACHE_SCAN_LINE_SIZES) \
		--ways $(DCACHE_SCAN_WAYS) \
		$(DCACHE_MODEL_ARGUMENTS) \
		--jobs $(DCACHE_SCAN_JOBS) \
		--ranking-metric blocking-tmt \
		--output $(DCACHE_SCAN_OUTPUT)

# ============================================================
# Branch-predictor simulation and design-space exploration
# ============================================================

# branch trace只保存已退休控制流，不保存错误路径。它适合比较预测算法的方向/目标
# 准确率和理想恢复代价；真实流水线中的训练时序、取指带宽与flush周期仍由RTL PMU校准。
BRANCH_TRACE_ARCH       ?= riscv64-nemu
BRANCH_TRACE_ISA        = riscv64
BRANCH_TRACE_SCALE      ?= test
BRANCH_TRACE_IMAGE      ?= $(MICROBENCH_DIR)/build/microbench-$(BRANCH_TRACE_ARCH).bin
BRANCH_TRACE_FILE       ?= $(abspath ./result/branch/$(BRANCH_TRACE_ISA)_microbench_$(BRANCH_TRACE_SCALE)_control_flow.bin)
BRANCH_TRACE_IMAGE_PATH = $(abspath $(BRANCH_TRACE_IMAGE))
BRANCH_TRACE_PATH       = $(abspath $(BRANCH_TRACE_FILE))

BRANCH_PREDICTOR          ?= bimodal
BRANCH_DIRECTION_ENTRIES  ?= 16
BRANCH_HISTORY_BITS       ?= 4
BRANCH_BTB_ENTRIES         ?= 0
BRANCH_BTB_WAYS            ?= 1
BRANCH_RAS_ENTRIES         ?= 0
BRANCH_SCAN_DIRECTION_ENTRIES ?= 16,32,64,128,256
BRANCH_SCAN_HISTORY_BITS      ?= 2,4,6,8
BRANCH_SCAN_BTB_ENTRIES        ?= 0,32,64
BRANCH_SCAN_BTB_WAYS           ?= 1,2
BRANCH_SCAN_RAS_ENTRIES        ?= 0,8
BRANCH_SCAN_JOBS               ?= 4
BRANCH_SCAN_OUTPUT             ?= $(abspath ./result/branch/branchsim_$(BRANCH_TRACE_ISA)_$(BRANCH_TRACE_SCALE)_exploration.csv)

$(BRANCHSIM_BUILD_DIR):
	mkdir -p $@

$(BRANCHSIM_BINARY): $(BRANCHSIM_SOURCE) | $(BRANCHSIM_BUILD_DIR)
	$(CXX) -std=c++17 -O3 -Wall -Wextra -Wpedantic -Werror $< -o $@

.PHONY: branchsim-build branchsim-test branchsim-trace branchsim-run branchsim-explore
branchsim-build: $(BRANCHSIM_BINARY)

branchsim-test: $(BRANCHSIM_BINARY)
	python3 $(BRANCHSIM_TEST_SCRIPT) $(BRANCHSIM_BINARY)

branchsim-trace:
	@test "$(BRANCH_TRACE_ARCH)" = "riscv64-nemu" || \
		(echo "BRANCH_TRACE_ARCH must be riscv64-nemu"; exit 1)
	$(MAKE) -C $(NEMU_DIR) riscv64-cachesim_defconfig
	$(MAKE) -C $(MICROBENCH_DIR) ARCH=$(BRANCH_TRACE_ARCH) clean
	$(MAKE) -C $(MICROBENCH_DIR) \
		ARCH=$(BRANCH_TRACE_ARCH) mainargs=$(BRANCH_TRACE_SCALE) insert-arg
	mkdir -p $(dir $(BRANCH_TRACE_PATH))
	$(MAKE) -C $(NEMU_DIR) run \
		ARGS="--branchsim-trace=$(BRANCH_TRACE_PATH) -b" \
		IMG=$(BRANCH_TRACE_IMAGE_PATH)
	@echo "NEMU retired control-flow trace: $(BRANCH_TRACE_PATH)"

branchsim-run: $(BRANCHSIM_BINARY)
	@test -f "$(BRANCH_TRACE_PATH)" || \
		(echo "branch trace file not found: $(BRANCH_TRACE_PATH)"; exit 1)
	$(BRANCHSIM_BINARY) \
		--trace $(BRANCH_TRACE_PATH) \
		--predictor $(BRANCH_PREDICTOR) \
		--direction-entries $(BRANCH_DIRECTION_ENTRIES) \
		--history-bits $(BRANCH_HISTORY_BITS) \
		--btb-entries $(BRANCH_BTB_ENTRIES) \
		--btb-ways $(BRANCH_BTB_WAYS) \
		--ras-entries $(BRANCH_RAS_ENTRIES)

branchsim-explore: $(BRANCHSIM_BINARY)
	@test -f "$(BRANCH_TRACE_PATH)" || \
		(echo "branch trace file not found: $(BRANCH_TRACE_PATH)"; exit 1)
	python3 $(BRANCHSIM_EXPLORE_SCRIPT) \
		--binary $(BRANCHSIM_BINARY) \
		--trace $(BRANCH_TRACE_PATH) \
		--direction-entries $(BRANCH_SCAN_DIRECTION_ENTRIES) \
		--history-bits $(BRANCH_SCAN_HISTORY_BITS) \
		--btb-entries $(BRANCH_SCAN_BTB_ENTRIES) \
		--btb-ways $(BRANCH_SCAN_BTB_WAYS) \
		--ras-entries $(BRANCH_SCAN_RAS_ENTRIES) \
		--jobs $(BRANCH_SCAN_JOBS) \
		--output $(BRANCH_SCAN_OUTPUT)

# ============================================================
# Reproducible performance evaluation
# ============================================================

# One measurement implementation for native timer windows in calibrated ysyxSoC.
PERF_SCALE ?= train
PERF_ISA ?= rv64im
PERF_OUTPUT ?=
.PHONY: perf perf-prepare perf-record
perf perf-record:
	python3 scripts/run_microbench_perf.py --scale $(PERF_SCALE) --isa $(PERF_ISA) $(if $(PERF_OUTPUT),--output $(PERF_OUTPUT))
perf-prepare:
	python3 scripts/run_microbench_perf.py --scale $(PERF_SCALE) --isa $(PERF_ISA) --prepare-only $(if $(PERF_OUTPUT),--output $(PERF_OUTPUT))

# Read-only comparison of two archives; this target never starts a simulation.
.PHONY: perf-compare
perf-compare:
	@test -n "$(BASELINE)" -a -n "$(CANDIDATE)" || (echo "Set BASELINE and CANDIDATE to result directories"; exit 1)
	python3 scripts/compare_soc_performance.py "$(BASELINE)" "$(CANDIDATE)"

# Used by the runner instead of duplicating cache/frequency defaults in Python.
.PHONY: print-sim-config
print-sim-config:
	@echo cpu_mhz=$(NPC_SIM_CPU_FREQ_MHZ)
	@echo simulator=$(SOC_SIM_BINARY)
	@echo config=$(NPC_CONFIG)
	@echo sdram_native_read_burst=$(NPC_SDRAM_NATIVE_READ_BURST)
	@echo icache=$(NPC_ICACHE_CAPACITY_BYTES),$(NPC_ICACHE_WAY_COUNT),$(NPC_ICACHE_LINE_BYTES),$(NPC_ICACHE_REPLACEMENT_POLICY)
	@echo dcache=$(NPC_DCACHE_ENABLE),$(NPC_DCACHE_CAPACITY_BYTES),$(NPC_DCACHE_WAY_COUNT),$(NPC_DCACHE_LINE_BYTES)
	@echo predictor=$(NPC_BRANCH_HISTORY_ENTRY_COUNT),$(NPC_BRANCH_TARGET_ENTRY_COUNT),$(NPC_BRANCH_TARGET_WAY_COUNT),$(NPC_RETURN_STACK_ENTRY_COUNT)

# ============================================================
# Static checks and maintenance
# ============================================================

.PHONY: lint lint-npc lint-soc lint-configs sta sta-configs clean
lint: lint-soc

lint-npc: $(RTL_FILELIST)
	$(call git_commit, "sim RTL") # DO NOT REMOVE THIS LINE!!!
	$(VERILATOR) --lint-only -Wall -Wno-fatal \
		$(NPC_CONFIG_DEFINE) \
		--top-module $(NPC_TOP_MODULE) \
		-f $(RTL_FILELIST)

lint-soc: $(RTL_FILELIST) $(SOC_VERILOG_SOURCES)
	$(call git_commit, "sim RTL") # DO NOT REMOVE THIS LINE!!!
	$(VERILATOR) --lint-only -Wall -Wno-fatal \
		$(NPC_CONFIG_DEFINE) $(NPC_SIM_TIMING_DEFINE) \
		$(SOC_RTL_INCLUDE_FLAGS) \
		--top-module $(SOC_TOP_MODULE) \
		-f $(RTL_FILELIST) \
		$(SOC_VERILOG_SOURCES)

lint-configs:
	$(MAKE) lint-npc PROJECT=$(PROJECT) NPC_CONFIG=$(NPC_CONFIG)

# 默认验收处理器与真实复位边界；不包含仿真内存和外设。
STA_TOOL_DIR      := $(abspath ../yosys-sta)
STA_DESIGN        := riscv_core
STA_FREQUENCY_MHZ ?= 700
STA_SYNTH_STRATEGY ?= AREA 3
STA_RUN_POWER_ANALYSIS ?= 0
STA_SDC_FILE      := $(abspath ./constr/riscv_core.sdc)
STA_PDK           ?= nangate45
STA_OUTPUT_ROOT   := $(abspath ./result/sta-current)

.PHONY: sta sta-core
sta: sta-qualified

# 原始纯核诊断保留；其工具退出码不代表完整时序、电气验收。
sta-core: $(STA_RTL_FILELIST) $(STA_RTL_DEPENDENCIES) $(STA_SDC_FILE)
	$(MAKE) -C $(STA_TOOL_DIR) sta \
		NPC_HOME=$(abspath .) \
		DESIGN=$(STA_DESIGN) \
		PDK=$(STA_PDK) \
		RTL_FILES="$(STA_RTL_DEPENDENCIES)" \
		SLANG_FLAGS="$(NPC_SLANG_DEFINE)" \
		SDC_FILE=$(STA_SDC_FILE) \
		O=$(STA_OUTPUT_ROOT) \
		CLK_FREQ_MHZ=$(STA_FREQUENCY_MHZ) \
		SYNTH_STRATEGY="$(STA_SYNTH_STRATEGY)" \
		RUN_POWER_ANALYSIS=$(STA_RUN_POWER_ANALYSIS) \
		CLK_PORT_NAME=clk_i

# 完整综合后验收：真实复位边界、负载修复、连接审计、时序与电气检查。
# sta 与 sta-qualified 使用同一验收入口，失败必须返回非零。
# 若仅 setup 失败，最多三轮对少量组合单元增强驱动，每轮重做完整验收。
STA_MAPPING_FREQUENCY_MHZ ?= 820
STA_YOSYS ?= yosys
STA_YOSYS_PLUGIN_FLAGS ?= -m slang
STA_SYNTH_SCRIPT := $(abspath ./scripts/synth_timing.tcl)
# 默认按实际电容约束修复；0 表示不额外限制扇出，1.0 表示使用完整库电容上限。
STA_MAX_FANOUT ?= 0
STA_CAPACITANCE_FRACTION ?= 1.0
STA_QUALIFIED_FREQUENCY_MHZ ?= $(STA_FREQUENCY_MHZ)
# Enable verbose Yosys debug output only when investigating the synthesis flow.
STA_YOSYS_DEBUG_FLAGS ?=
STA_QUALIFIED_OUTPUT_DIR ?= $(STA_OUTPUT_ROOT)/riscv_core_reset_boundary-$(STA_QUALIFIED_FREQUENCY_MHZ)MHz-qualified

.PHONY: sta-qualified test-timing test-synthesis-target
sta-qualified: $(STA_RTL_FILELIST) $(STA_RTL_DEPENDENCIES) constr/riscv_core_reset_boundary.sdc $(STA_SYNTH_SCRIPT)
	@test "$(STA_PDK)" = nangate45 || (echo "sta-qualified currently uses Nangate45"; exit 1)
	mkdir -p $(STA_OUTPUT_ROOT)/riscv_core_reset_boundary-$(STA_MAPPING_FREQUENCY_MHZ)MHz
	$(STA_YOSYS) $(STA_YOSYS_PLUGIN_FLAGS) $(STA_YOSYS_DEBUG_FLAGS) \
		-l $(STA_OUTPUT_ROOT)/riscv_core_reset_boundary-$(STA_MAPPING_FREQUENCY_MHZ)MHz/yosys.log \
		-p 'tcl $(STA_SYNTH_SCRIPT) $(STA_TOOL_DIR) riscv_core_reset_boundary $(STA_PDK) "$(NPC_SLANG_DEFINE) $(STA_RTL_DEPENDENCIES)" $(STA_OUTPUT_ROOT)/riscv_core_reset_boundary-$(STA_MAPPING_FREQUENCY_MHZ)MHz/riscv_core_reset_boundary.netlist.v $(STA_MAPPING_FREQUENCY_MHZ)'
	python3 scripts/qualify_mapped_sta.py \
		--netlist $(STA_OUTPUT_ROOT)/riscv_core_reset_boundary-$(STA_MAPPING_FREQUENCY_MHZ)MHz/riscv_core_reset_boundary.netlist.v \
		--toolflow $(STA_TOOL_DIR) --sdc constr/riscv_core_reset_boundary.sdc \
		--output $(STA_QUALIFIED_OUTPUT_DIR) --frequency $(STA_QUALIFIED_FREQUENCY_MHZ) \
		--fanout $(STA_MAX_FANOUT) --headroom $(STA_CAPACITANCE_FRACTION)

TIMING_TEST_OUTPUT_DIR ?= $(abspath ./build/tests/timing/$(NPC_CONFIG))
test-synthesis-target:
	python3 tests/timing/test_synthesis_target.py --toolflow $(STA_TOOL_DIR) --output "$(TIMING_TEST_OUTPUT_DIR)/mapping-target"

test-timing: test-synthesis-target
	python3 tests/timing/run.py --output $(TIMING_TEST_OUTPUT_DIR) $(NPC_CONFIG_DEFINE)
	python3 tests/timing/test_mapped_fanout.py
	python3 tests/timing/test_buffer_refinement.py
	python3 tests/timing/test_sta_acceptance.py
	python3 tests/timing/test_clock_buffer_constraints.py --toolflow $(STA_TOOL_DIR) --output "$(TIMING_TEST_OUTPUT_DIR)/clock-coverage"
	python3 tests/timing/test_critical_drive.py --liberty $(STA_TOOL_DIR)/pdk/nangate45/lib/Nangate45_typ.lib

sta-configs:
	$(MAKE) sta PROJECT=$(PROJECT) NPC_CONFIG=$(NPC_CONFIG)

clean:
	rm -rf ./build wave.vcd waveform.vcd

# ysyx tracing helper and workspace-level variables.
include ../Makefile

-include $(wildcard $(NPC_OBJ_DIR)/*.d)
-include $(wildcard $(SOC_OBJ_DIR)/*.d)
-include $(wildcard $(NVBOARD_OBJ_DIR)/*.d)

.PHONY: help
help:
	@echo "Usage: make <target> PROJECT=riscv NPC_CONFIG=<config> [IMG=...]"
	@echo "Configs: $(SUPPORTED_NPC_CONFIGS)"
	@echo ""
	@echo "Build targets:"
	@echo "  build-npc     Compatibility alias of build-soc"
	@echo "  build-soc     Build ysyxSoC; RV64 uses the AXI64-to-AXI32 boundary converter"
	@echo "  test-configs  Check the RV64 static configuration contract"
	@echo "  test-idu-configs  Run directed RV64 IDU tests"
	@echo "  test-exu-configs  Run directed RV64 EXU tests"
	@echo "  test-lsu-configs  Run directed RV64 LSU tests"
	@echo "  test-pipeline-configs  Test pipeline registers, hazards, and redirects"
	@echo "  test-uncached-configs  Run uncached AXI4 tests"
	@echo "  test-dcache-configs  Test D-cache hit, refill, writeback, and clean"
	@echo "  test-core-merge-configs  Test I/D shared AXI read arbitration"
	@echo "  test-soc-width-converter  Test RV64 AXI to ysyxSoC AXI32 conversion"
	@echo "  test-sdram-axi  Test AXI transaction classification and native SDRAM BL8 reads"
	@echo "  test-axi-delayer  Test per-beat AXI read timing and independent write timing"
	@echo "  test-privileged-configs  Test RV64 CSR, trap, commit, and PMU semantics"
	@echo "  nemu-ref-rv64  Build the RV64 SoC Flash/SRAM/SDRAM DiffTest reference"
	@echo "  test-icache        Check I-cache refill, errors, backpressure and invalidate"
	@echo "  test-icache-replacement  Check policy 13 against an independent cache model"
	@echo "  regression-rv64-isa  Run CPU and exception DiffTests"
	@echo "  regression-rv64  Run the complete RV64 directed and ISA regression"
	@echo ""
	@echo "Run targets:"
	@echo "  sim           Run the calibrated SoC; requires FLASH_IMG"
	@echo "  sim-soc       Run calibrated ysyxSoC; requires FLASH_IMG"
	@echo "  sim-npc       Compatibility alias of sim-soc"
	@echo "  sim-am        AM compatibility alias of sim-soc"
	@echo "  sim-image     ysyxSoC AM compatibility alias of sim-soc"
	@echo "  nvboard       Run ysyxSoC with NVBoard"
	@echo ""
	@echo "Debug targets use the same calibrated ysyxSoC:"
	@echo "  sim-itrace sim-mtrace sim-ftrace sim-trace"
	@echo "  sim-difftest sim-wave sim-debug"
	@echo ""
	@echo "Evaluation targets:"
	@echo "  perf          Run calibrated SoC MicroBench and validate native timer windows"
	@echo "  perf-prepare  Build/archive train without running; perf-record aliases perf"
	@echo "  cachesim-test Build and test the metadata-only I-cache simulator"
	@echo "  cachesim-trace  Generate an architectural PC trace with NEMU"
	@echo "  cachesim-run    Evaluate one cache configuration"
	@echo "  cachesim-explore  Scan cache capacity, line size, and associativity"
	@echo "  cachesim-explore-baseline  Reproduce the fixed-penalty baseline"
	@echo "  cachesim-explore-transport  Compare independent reads with AXI4 burst"
	@echo "  dcachesim-trace  Generate an architectural load/store trace with NEMU"
	@echo "  dcachesim-run    Evaluate one write-back/write-allocate D-cache"
	@echo "  dcachesim-explore  Scan D-cache capacity, line size, and associativity"
	@echo "  branchsim-test   Build and test the branch predictor simulator"
	@echo "  branchsim-trace  Generate a retired control-flow trace with NEMU"
	@echo "  branchsim-run    Evaluate one direction/target predictor"
	@echo "  branchsim-explore  Scan BHT, gshare, BTB, and RAS parameters"
	@echo "  icache-calibrate-penalty  Measure per-line-size miss penalties in RTL"
	@echo "  cachesim-explore-calibrated  Explore using the RTL calibration CSV"
	@echo "  lint-npc      Lint the standalone NPC"
	@echo "  lint-soc      Lint the selected NPC configuration inside ysyxSoC"
	@echo "  lint-configs  Lint the RV64 edge-AI configuration"
	@echo "  sta / sta-qualified  Qualify core and reset boundary at 700 MHz by default"
	@echo "  sta-core      Run raw core-only STA for diagnosis"
	@echo "  test-timing   Test reset sequencing and mapped-netlist checks"
	@echo ""
	@echo "Examples:"
	@echo "  make lint-npc"
	@echo "  make lint-npc NPC_ICACHE_LINE_BYTES=128"
	@echo "  make sim-npc IMG=path/to/riscv64-npc.bin"

.PHONY: test-execution-units
test-execution-units:
	python3 scripts/test_execution_units.py --output $(abspath ./build/tests/execution-units/$(NPC_CONFIG)) $(NPC_CONFIG_DEFINE)

.PHONY: test-execution-core
EXECUTION_TEST_OUTPUT_DIR ?= $(abspath ./build/tests/execution-core/$(NPC_CONFIG))
test-execution-core: $(SOC_SIM_BINARY) nemu-ref-rv64
	python3 scripts/build_execution_payload.py --output $(EXECUTION_TEST_OUTPUT_DIR)
	$(SOC_SIM_BINARY) --batch --diff $(RV64_NEMU_REF) --flash $(EXECUTION_TEST_OUTPUT_DIR)/rv64m-core.bin

.PHONY: test-scoreboard
test-scoreboard:
	mkdir -p $(abspath ./build/tests/scoreboard)
	$(VERILATOR) --binary --timing --assert -Wno-fatal -j 2 $(NPC_CONFIG_DEFINE) \
		--top-module riscv_scoreboard_tb -I$(abspath ./vsrc/riscv/sim) -f $(STA_RTL_FILELIST) \
		$(abspath ./tests/rtl/riscv_scoreboard_tb.sv) \
		--Mdir $(abspath ./build/tests/scoreboard/obj)
	$(abspath ./build/tests/scoreboard/obj/Vriscv_scoreboard_tb)

.PHONY: test-scoreboard-core
test-scoreboard-core:
	mkdir -p $(abspath ./build/tests/scoreboard-core)
	$(VERILATOR) --binary --timing --assert -Wno-fatal -j 2 $(NPC_CONFIG_DEFINE) \
		-CFLAGS -O0 -MAKEFLAGS 'OPT_FAST=-O0 OPT_SLOW=-O0' \
		--top-module riscv_scoreboard_core_tb -I$(abspath ./vsrc/riscv/sim) -f $(STA_RTL_FILELIST) \
		$(abspath ./tests/rtl/riscv_scoreboard_core_tb.sv) \
		--Mdir $(abspath ./build/tests/scoreboard-core/obj)
	$(abspath ./build/tests/scoreboard-core/obj/Vriscv_scoreboard_core_tb) +mode=0
	$(abspath ./build/tests/scoreboard-core/obj/Vriscv_scoreboard_core_tb) +mode=1
	$(abspath ./build/tests/scoreboard-core/obj/Vriscv_scoreboard_core_tb) +mode=2
	$(abspath ./build/tests/scoreboard-core/obj/Vriscv_scoreboard_core_tb) +mode=3
	$(abspath ./build/tests/scoreboard-core/obj/Vriscv_scoreboard_core_tb) +mode=4
	$(abspath ./build/tests/scoreboard-core/obj/Vriscv_scoreboard_core_tb) +mode=5
	$(abspath ./build/tests/scoreboard-core/obj/Vriscv_scoreboard_core_tb) +mode=6

# Protocol benches are component verification, never program performance measurements.
.PHONY: test-soc-timing
test-soc-timing: test-axi-delayer test-soc-width-converter
	python3 scripts/test_soc_timing.py

.PHONY: test-operand-wait
test-operand-wait:
	mkdir -p $(abspath ./build/tests/operand-wait)
	$(VERILATOR) --binary --timing --assert -Wno-fatal -j 2 $(NPC_CONFIG_DEFINE) \
		--top-module riscv_operand_wait_tb -I$(abspath ./vsrc/riscv/sim) -f $(STA_RTL_FILELIST) \
		$(abspath ./tests/rtl/riscv_operand_wait_tb.sv) \
		--Mdir $(abspath ./build/tests/operand-wait/obj)
	$(abspath ./build/tests/operand-wait/obj/Vriscv_operand_wait_tb)
