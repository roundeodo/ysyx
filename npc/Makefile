.DEFAULT_GOAL := help

# ============================================================
# Project and build layout
# ============================================================

PROJECT ?= riscv32
# rv32-baseline用于RV32I性能开发，rv32-course-area保留课程面积对照。两者共享
# ISA语义和模块协议，只改变被实例化的微架构资源。默认值来自同一workload、同一
# NanGate45流程的A/B实验；命令行仍可覆盖参数继续探索设计空间。
ifeq ($(NPC_CONFIG),rv32-course-area)
NPC_ICACHE_WAY_COUNT      ?= 1
NPC_ICACHE_CAPACITY_BYTES ?= 128
NPC_ICACHE_LINE_BYTES     ?= 16
NPC_DCACHE_ENABLE         ?= 0
NPC_DCACHE_WAY_COUNT      ?= 2
NPC_DCACHE_CAPACITY_BYTES ?= 256
NPC_DCACHE_LINE_BYTES     ?= 16
else ifeq ($(NPC_CONFIG),rv64-sequential)
NPC_ICACHE_WAY_COUNT      ?= 2
NPC_ICACHE_CAPACITY_BYTES ?= 64
NPC_ICACHE_LINE_BYTES     ?= 16
NPC_DCACHE_ENABLE         ?= 1
NPC_DCACHE_WAY_COUNT      ?= 2
NPC_DCACHE_CAPACITY_BYTES ?= 1024
NPC_DCACHE_LINE_BYTES     ?= 32
else
# RV32I平衡点：I-cache扩大到256 B后前端miss显著下降；256 B/2-way D-cache相对
# 同容量direct-map只增加约1.35%面积，却把MicroBench测量IPC再提高约10.4%。
NPC_ICACHE_WAY_COUNT      ?= 1
NPC_ICACHE_CAPACITY_BYTES ?= 256
NPC_ICACHE_LINE_BYTES     ?= 16
NPC_DCACHE_ENABLE         ?= 1
NPC_DCACHE_WAY_COUNT      ?= 2
NPC_DCACHE_CAPACITY_BYTES ?= 256
NPC_DCACHE_LINE_BYTES     ?= 16
endif
NPC_SDRAM_NATIVE_READ_BURST ?= 1
NPC_BRANCH_HISTORY_ENTRY_COUNT ?= 16
# MicroBench A/B中，16项2路BTB与32项2路性能等价，但预测状态接近减半。
NPC_BRANCH_TARGET_ENTRY_COUNT  ?= 16
NPC_BRANCH_TARGET_WAY_COUNT    ?= 2
NPC_RETURN_STACK_ENTRY_COUNT   ?= 4

# 显式频率同时控制 CLINT 微秒和设备延迟。空值仅用于复现历史计时环境。
NPC_SIM_CPU_FREQ_MHZ ?=
ifneq ($(strip $(NPC_SIM_CPU_FREQ_MHZ)),)
NPC_SIM_TIMING_DEFINE := +define+YSYX_SIM_CPU_FREQ_MHZ=$(NPC_SIM_CPU_FREQ_MHZ)
endif

ifeq ($(filter $(NPC_DCACHE_ENABLE),0 1),)
$(error NPC_DCACHE_ENABLE must be 0 or 1)
endif
ifeq ($(filter $(NPC_SDRAM_NATIVE_READ_BURST),0 1),)
$(error NPC_SDRAM_NATIVE_READ_BURST must be 0 or 1)
endif

SUPPORTED_NPC_CONFIGS := rv32-course-area rv32-baseline rv64-sequential
CONFIG_FREE_GOALS     := help clean lint-configs sta-configs test-configs test-idu-configs test-exu-configs test-lsu-configs test-pipeline-configs formal-pipeline test-uncached-configs test-dcache-configs test-core-merge-configs test-sdram-axi test-axi-delayer test-privileged-configs nemu-ref-rv32 nemu-ref-rv64 regression-p3-e regression-p3-f-rv32 regression-p3-f-rv64 regression-p3-g perf-record cachesim-build cachesim-test cachesim-trace cachesim-run cachesim-explore cachesim-explore-transport dcachesim-trace dcachesim-run dcachesim-explore branchsim-build branchsim-test branchsim-trace branchsim-run branchsim-explore icache-calibrate-penalty cachesim-explore-calibrated
CONFIG_REQUIRED_GOALS := $(filter-out $(CONFIG_FREE_GOALS),$(MAKECMDGOALS))

ifneq ($(strip $(CONFIG_REQUIRED_GOALS)),)
ifeq ($(strip $(NPC_CONFIG)),)
$(error NPC_CONFIG is required: $(SUPPORTED_NPC_CONFIGS))
endif
ifeq ($(filter $(NPC_CONFIG),$(SUPPORTED_NPC_CONFIGS)),)
$(error unsupported NPC_CONFIG=$(NPC_CONFIG); expected one of: $(SUPPORTED_NPC_CONFIGS))
endif
endif

ifeq ($(NPC_CONFIG),rv32-baseline)
NPC_ARCH_DEFINE := +define+YSYX_RV32_BASELINE
NPC_CONFIG_CXXFLAG := -DNPC_XLEN=32
NPC_SLANG_ARCH_DEFINE := -DYSYX_RV32_BASELINE
else ifeq ($(NPC_CONFIG),rv32-course-area)
NPC_ARCH_DEFINE := +define+YSYX_RV32_BASELINE +define+YSYX_RV32_COURSE_AREA
NPC_CONFIG_CXXFLAG := -DNPC_XLEN=32
NPC_SLANG_ARCH_DEFINE := -DYSYX_RV32_BASELINE -DYSYX_RV32_COURSE_AREA
else ifeq ($(NPC_CONFIG),rv64-sequential)
NPC_ARCH_DEFINE := +define+YSYX_RV64_SEQUENTIAL
NPC_CONFIG_CXXFLAG := -DNPC_XLEN=64
NPC_SLANG_ARCH_DEFINE := -DYSYX_RV64_SEQUENTIAL
endif

NPC_CONFIG_DEFINE := $(NPC_ARCH_DEFINE) $(NPC_SIM_TIMING_DEFINE) \
	+define+YSYX_ICACHE_CAPACITY_BYTES=$(NPC_ICACHE_CAPACITY_BYTES) \
	+define+YSYX_ICACHE_WAY_COUNT=$(NPC_ICACHE_WAY_COUNT) \
	+define+YSYX_ICACHE_LINE_BYTES=$(NPC_ICACHE_LINE_BYTES) \
	+define+YSYX_DCACHE_ENABLE=$(NPC_DCACHE_ENABLE) \
	+define+YSYX_DCACHE_CAPACITY_BYTES=$(NPC_DCACHE_CAPACITY_BYTES) \
	+define+YSYX_DCACHE_WAY_COUNT=$(NPC_DCACHE_WAY_COUNT) \
	+define+YSYX_DCACHE_LINE_BYTES=$(NPC_DCACHE_LINE_BYTES) \
	+define+YSYX_BRANCH_HISTORY_ENTRY_COUNT=$(NPC_BRANCH_HISTORY_ENTRY_COUNT) \
	+define+YSYX_BRANCH_TARGET_ENTRY_COUNT=$(NPC_BRANCH_TARGET_ENTRY_COUNT) \
	+define+YSYX_BRANCH_TARGET_WAY_COUNT=$(NPC_BRANCH_TARGET_WAY_COUNT) \
	+define+YSYX_RETURN_STACK_ENTRY_COUNT=$(NPC_RETURN_STACK_ENTRY_COUNT) \
	+define+YSYX_SDRAM_NATIVE_READ_BURST=$(NPC_SDRAM_NATIVE_READ_BURST)

NPC_SLANG_DEFINE := $(NPC_SLANG_ARCH_DEFINE) \
	-DYSYX_ICACHE_CAPACITY_BYTES=$(NPC_ICACHE_CAPACITY_BYTES) \
	-DYSYX_ICACHE_WAY_COUNT=$(NPC_ICACHE_WAY_COUNT) \
	-DYSYX_ICACHE_LINE_BYTES=$(NPC_ICACHE_LINE_BYTES) \
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
BUILD_DIR := $(abspath ./build/$(PROJECT)/$(NPC_CONFIG))/icache-$(NPC_ICACHE_CAPACITY_BYTES)b-way-$(NPC_ICACHE_WAY_COUNT)-line-$(NPC_ICACHE_LINE_BYTES)b/$(DCACHE_BUILD_TAG)/$(PREDICTOR_BUILD_TAG)
ifeq ($(NPC_SDRAM_NATIVE_READ_BURST),0)
BUILD_DIR := $(BUILD_DIR)/sdram-read-bl1
endif
ifneq ($(strip $(NPC_SIM_CPU_FREQ_MHZ)),)
BUILD_DIR := $(BUILD_DIR)/sim-cpu-$(NPC_SIM_CPU_FREQ_MHZ)mhz-device-100mhz
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
RV32_NEMU_REF := $(NEMU_DIR)/build/riscv32-nemu-interpreter-so
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

# 只收录能够在standalone内存环境中验证RV32I/RV64I、Zicsr和异常闭环的测试。
# unalign要求硬件透明处理非对齐访问，与当前“产生misaligned异常”的架构契约冲突；
# GPIO、PSRAM、SDRAM、SPI等测试属于ysyxSoC外设回归，不放进处理器ISA基线。
P3_CPU_TESTS := \
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
RTL_DEPENDENCIES := $(wildcard $(RTL_DIR)/sim/*.svh) $(shell sed \
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

SIM_CPP_HEADERS := $(wildcard $(abspath ./include)/*.h)

# ============================================================
# Verilator and C++ configuration
# ============================================================

VERILATOR ?= verilator
VERILATOR_FLAGS := \
	-MMD --build -cc -Wall -Wno-fatal \
	-O3 --x-assign fast --x-initial fast \
	-I$(RTL_DIR)/sim \
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
	$(RTL_DIR)/common/riscv32_addr_map_pkg.sv \
	$(RTL_DIR)/common/riscv32_pkg.sv \
	$(RTL_DIR)/core/decode/riscv32_idu.sv \
	$(abspath ./tests/rtl/riscv32_idu_decode_tb.sv)

EXU_TEST_SOURCES := \
	$(RTL_DIR)/common/riscv_config_pkg.sv \
	$(RTL_DIR)/common/riscv32_addr_map_pkg.sv \
	$(RTL_DIR)/common/riscv32_pkg.sv \
	$(RTL_DIR)/core/execute/riscv32_exu.sv \
	$(abspath ./tests/rtl/riscv32_exu_alu_tb.sv)

LSU_TEST_SOURCES := \
	$(RTL_DIR)/common/riscv_config_pkg.sv \
	$(RTL_DIR)/common/riscv32_addr_map_pkg.sv \
	$(RTL_DIR)/common/riscv32_pkg.sv \
	$(RTL_DIR)/core/memory/riscv32_lsu.sv \
	$(abspath ./tests/rtl/riscv32_lsu_tb.sv)

PIPELINE_TEST_SOURCES := \
	$(RTL_DIR)/common/riscv_config_pkg.sv \
	$(RTL_DIR)/common/riscv32_addr_map_pkg.sv \
	$(RTL_DIR)/common/riscv32_pkg.sv \
	$(RTL_DIR)/core/execute/riscv32_id_ex_reg.sv \
	$(RTL_DIR)/core/control/riscv32_hazard_ctrl.sv \
	$(RTL_DIR)/core/writeback/riscv32_completion_mux.sv \
	$(RTL_DIR)/core/writeback/riscv32_wb_reg.sv \
	$(RTL_DIR)/core/writeback/riscv32_commit.sv \
	$(RTL_DIR)/core/control/riscv32_trap_ctrl.sv \
	$(RTL_DIR)/core/frontend/riscv32_fetch_buffer.sv \
	$(RTL_DIR)/core/frontend/riscv32_bht.sv \
	$(RTL_DIR)/core/frontend/riscv32_btb.sv \
	$(RTL_DIR)/core/frontend/riscv32_ras.sv \
	$(RTL_DIR)/core/frontend/riscv32_branch_predictor.sv \
	$(RTL_DIR)/core/frontend/riscv32_ifu.sv \
	$(abspath ./tests/rtl/riscv32_pipeline_control_tb.sv)

UNCACHED_TEST_SOURCES := \
	$(RTL_DIR)/common/riscv_config_pkg.sv \
	$(RTL_DIR)/common/riscv32_addr_map_pkg.sv \
	$(RTL_DIR)/common/riscv32_axi4_pkg.sv \
	$(RTL_DIR)/common/riscv32_pkg.sv \
	$(RTL_DIR)/core/memory/riscv32_uncached_axi.sv \
	$(abspath ./tests/rtl/riscv32_uncached_axi4_master_tb.sv)

DCACHE_TEST_SOURCES := \
	$(RTL_DIR)/common/riscv_config_pkg.sv \
	$(RTL_DIR)/common/riscv32_addr_map_pkg.sv \
	$(RTL_DIR)/common/riscv32_axi4_pkg.sv \
	$(RTL_DIR)/common/riscv32_pkg.sv \
	$(RTL_DIR)/core/memory/riscv32_dcache_tag_array.sv \
	$(RTL_DIR)/core/memory/riscv32_dcache_data_array.sv \
	$(RTL_DIR)/core/memory/riscv32_dcache_axi.sv \
	$(RTL_DIR)/core/memory/riscv32_dcache_miss_unit.sv \
	$(RTL_DIR)/core/memory/riscv32_dcache.sv \
	$(abspath ./tests/rtl/riscv32_dcache_tb.sv)

CORE_MERGE_TEST_SOURCES := \
	$(RTL_DIR)/common/riscv_config_pkg.sv \
	$(RTL_DIR)/common/riscv32_axi4_pkg.sv \
	$(RTL_DIR)/system/riscv32_axi4_arbiter.sv \
	$(abspath ./tests/rtl/riscv32_axi4_core_merge_tb.sv)

SOC_WIDTH_CONVERTER_TEST_SOURCES := \
	$(RTL_DIR)/common/riscv_config_pkg.sv \
	$(RTL_DIR)/common/riscv32_addr_map_pkg.sv \
	$(RTL_DIR)/common/riscv32_axi4_pkg.sv \
	$(RTL_DIR)/common/riscv32_ysyx_soc_axi4_pkg.sv \
	$(RTL_DIR)/common/riscv32_pkg.sv \
	$(RTL_DIR)/core/frontend/riscv32_pma.sv \
	$(RTL_DIR)/system/riscv32_axi4_soc_width_converter.sv \
	$(abspath ./tests/rtl/riscv32_axi4_soc_width_converter_tb.sv)

PRIVILEGED_TEST_SOURCES := \
	$(RTL_DIR)/common/riscv_config_pkg.sv \
	$(RTL_DIR)/common/riscv32_addr_map_pkg.sv \
	$(RTL_DIR)/common/riscv32_pkg.sv \
	$(RTL_DIR)/core/writeback/riscv32_pmu.sv \
	$(RTL_DIR)/core/writeback/riscv32_csr_file.sv \
	$(RTL_DIR)/core/writeback/riscv32_commit.sv \
	$(RTL_DIR)/core/control/riscv32_trap_ctrl.sv \
	$(abspath ./tests/rtl/riscv32_privileged_tb.sv)

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
$(NPC_SIM_BINARY): $(RTL_FILELIST) $(RTL_DEPENDENCIES) $(SIM_CPP_SOURCES) $(SIM_CPP_HEADERS) | $(BUILD_DIR)
	$(call git_commit, "sim RTL") # DO NOT REMOVE THIS LINE!!!
	$(VERILATOR) $(VERILATOR_FLAGS) \
		$(NPC_CONFIG_DEFINE) \
		--top-module $(NPC_TOP_MODULE) \
		-f $(RTL_FILELIST) \
		$(SIM_CPP_SOURCES) \
		$(addprefix -CFLAGS ,$(NPC_CXXFLAGS)) \
		$(addprefix -LDFLAGS ,$(COMMON_LDFLAGS)) \
		--Mdir $(NPC_OBJ_DIR) \
		--exe \
		-o $(NPC_SIM_BINARY)

# Accurate environment: CPU integrated into ysyxSoC and its peripherals.
$(SOC_SIM_BINARY): $(RTL_FILELIST) $(RTL_DEPENDENCIES) \
		$(SOC_VERILOG_SOURCES) $(SIM_CPP_SOURCES) $(SIM_CPP_HEADERS) | $(BUILD_DIR)
	$(call git_commit, "sim RTL") # DO NOT REMOVE THIS LINE!!!
	$(VERILATOR) $(VERILATOR_FLAGS) \
		$(NPC_CONFIG_DEFINE) \
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

$(NVBOARD_SIM_BINARY): $(RTL_FILELIST) $(RTL_DEPENDENCIES) \
		$(SOC_VERILOG_SOURCES) $(NVBOARD_CPP_SOURCES) $(NVBOARD_ARCHIVE) | $(BUILD_DIR)
	$(call git_commit, "sim nvboard") # DO NOT REMOVE THIS LINE!!!
	$(VERILATOR) $(VERILATOR_FLAGS) \
		$(NPC_CONFIG_DEFINE) \
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
		--top-module riscv32_idu_decode_tb \
		$(IDU_TEST_SOURCES) \
		--Mdir $(IDU_TEST_OBJ_DIR) \
		-o $(IDU_TEST_BINARY)

$(EXU_TEST_BINARY): $(EXU_TEST_SOURCES) | $(BUILD_DIR)
	$(VERILATOR) --binary --timing --assert -Wall -Wno-fatal -Wno-UNUSEDPARAM \
		-Wno-UNUSEDSIGNAL \
		$(NPC_CONFIG_DEFINE) \
		--top-module riscv32_exu_alu_tb \
		$(EXU_TEST_SOURCES) \
		--Mdir $(EXU_TEST_OBJ_DIR) \
		-o $(EXU_TEST_BINARY)

$(LSU_TEST_BINARY): $(LSU_TEST_SOURCES) | $(BUILD_DIR)
	$(VERILATOR) --binary --timing --assert -Wall -Wno-fatal -Wno-UNUSEDPARAM \
		-Wno-UNUSEDSIGNAL \
		$(NPC_CONFIG_DEFINE) \
		--top-module riscv32_lsu_tb \
		$(LSU_TEST_SOURCES) \
		--Mdir $(LSU_TEST_OBJ_DIR) \
		-o $(LSU_TEST_BINARY)

$(PIPELINE_TEST_BINARY): $(PIPELINE_TEST_SOURCES) | $(BUILD_DIR)
	$(VERILATOR) --binary --timing --assert -Wall -Wno-fatal -Wno-UNUSEDPARAM \
		-Wno-UNUSEDSIGNAL \
		$(NPC_CONFIG_DEFINE) \
		--top-module riscv32_pipeline_control_tb \
		$(PIPELINE_TEST_SOURCES) \
		--Mdir $(PIPELINE_TEST_OBJ_DIR) \
		-o $(PIPELINE_TEST_BINARY)

$(UNCACHED_TEST_BINARY): $(UNCACHED_TEST_SOURCES) | $(BUILD_DIR)
	$(VERILATOR) --binary --timing --assert -Wall -Wno-fatal -Wno-UNUSEDPARAM \
		-Wno-UNUSEDSIGNAL \
		$(NPC_CONFIG_DEFINE) \
		--top-module riscv32_uncached_axi4_master_tb \
		$(UNCACHED_TEST_SOURCES) \
		--Mdir $(UNCACHED_TEST_OBJ_DIR) \
		-o $(UNCACHED_TEST_BINARY)

$(DCACHE_TEST_BINARY): $(DCACHE_TEST_SOURCES) | $(BUILD_DIR)
	$(VERILATOR) --binary --timing --assert -Wall -Wno-fatal -Wno-UNUSEDPARAM \
		-Wno-UNUSEDSIGNAL \
		$(NPC_CONFIG_DEFINE) \
		--top-module riscv32_dcache_tb \
		$(DCACHE_TEST_SOURCES) \
		--Mdir $(DCACHE_TEST_OBJ_DIR) \
		-o $(DCACHE_TEST_BINARY)

$(CORE_MERGE_TEST_BINARY): $(CORE_MERGE_TEST_SOURCES) | $(BUILD_DIR)
	$(VERILATOR) --binary --timing --assert -Wall -Wno-fatal -Wno-UNUSEDPARAM \
		-Wno-UNUSEDSIGNAL \
		$(NPC_CONFIG_DEFINE) \
		--top-module riscv32_axi4_core_merge_tb \
		$(CORE_MERGE_TEST_SOURCES) \
		--Mdir $(CORE_MERGE_TEST_OBJ_DIR) \
		-o $(CORE_MERGE_TEST_BINARY)

$(SOC_WIDTH_CONVERTER_TEST_BINARY): $(SOC_WIDTH_CONVERTER_TEST_SOURCES) | $(BUILD_DIR)
	$(VERILATOR) --binary --timing --assert -Wall -Wno-fatal -Wno-UNUSEDPARAM \
		-Wno-UNUSEDSIGNAL \
		$(NPC_CONFIG_DEFINE) \
		--top-module riscv32_axi4_soc_width_converter_tb \
		$(SOC_WIDTH_CONVERTER_TEST_SOURCES) \
		--Mdir $(SOC_WIDTH_CONVERTER_TEST_OBJ_DIR) \
		-o $(SOC_WIDTH_CONVERTER_TEST_BINARY)

$(PRIVILEGED_TEST_BINARY): $(PRIVILEGED_TEST_SOURCES) | $(BUILD_DIR)
	$(VERILATOR) --binary --timing --assert -Wall -Wno-fatal -Wno-UNUSEDPARAM \
		-Wno-UNUSEDSIGNAL \
		$(NPC_CONFIG_DEFINE) \
		--top-module riscv32_privileged_tb \
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
build-npc: $(NPC_SIM_BINARY)
build-soc: $(SOC_SIM_BINARY)
test-config: $(CONFIG_TEST_BINARY)
	$(CONFIG_TEST_BINARY)

test-configs:
	$(MAKE) test-config PROJECT=$(PROJECT) NPC_CONFIG=rv32-course-area
	$(MAKE) test-config PROJECT=$(PROJECT) NPC_CONFIG=rv32-baseline
	$(MAKE) test-config PROJECT=$(PROJECT) NPC_CONFIG=rv64-sequential

test-idu: $(IDU_TEST_BINARY)
	$(IDU_TEST_BINARY)

test-idu-configs:
	$(MAKE) test-idu PROJECT=$(PROJECT) NPC_CONFIG=rv32-baseline
	$(MAKE) test-idu PROJECT=$(PROJECT) NPC_CONFIG=rv64-sequential

test-exu: $(EXU_TEST_BINARY)
	$(EXU_TEST_BINARY)

test-exu-configs:
	$(MAKE) test-exu PROJECT=$(PROJECT) NPC_CONFIG=rv32-baseline
	$(MAKE) test-exu PROJECT=$(PROJECT) NPC_CONFIG=rv64-sequential

test-lsu: $(LSU_TEST_BINARY)
	$(LSU_TEST_BINARY)

test-lsu-configs:
	$(MAKE) test-lsu PROJECT=$(PROJECT) NPC_CONFIG=rv32-baseline
	$(MAKE) test-lsu PROJECT=$(PROJECT) NPC_CONFIG=rv64-sequential

test-pipeline: $(PIPELINE_TEST_BINARY)
	$(PIPELINE_TEST_BINARY)

.PHONY: test-predictor test-icache test-fetch
FRONTEND_TEST_OUTPUT ?= $(abspath ./build/tests/frontend)
test-predictor:
	python3 scripts/test_frontend.py --test predictor --output "$(FRONTEND_TEST_OUTPUT)" $(NPC_CONFIG_DEFINE)

test-fetch:
	python3 scripts/test_frontend.py --test fetch --output "$(FRONTEND_TEST_OUTPUT)" $(NPC_CONFIG_DEFINE)

test-icache:
	python3 scripts/test_frontend.py --test icache --output "$(FRONTEND_TEST_OUTPUT)" $(NPC_CONFIG_DEFINE)

.PHONY: test-predictor-equivalence
PREDICTOR_TEST_OUTPUT ?= $(abspath ./build/tests/predictor-equivalence)
test-predictor-equivalence:
	@test "$(NPC_CONFIG)" = rv32-baseline || (echo "Use NPC_CONFIG=rv32-baseline"; exit 1)
	python3 scripts/test_predictor_equivalence.py --output "$(PREDICTOR_TEST_OUTPUT)" $(NPC_CONFIG_DEFINE)

test-pipeline-configs:
	$(MAKE) test-pipeline PROJECT=$(PROJECT) NPC_CONFIG=rv32-baseline
	$(MAKE) test-pipeline PROJECT=$(PROJECT) NPC_CONFIG=rv64-sequential

.PHONY: formal-pipeline
formal-pipeline:
	sby -f tests/formal/riscv32_pipeline_control.sby

test-uncached: $(UNCACHED_TEST_BINARY)
	$(UNCACHED_TEST_BINARY)

test-uncached-configs:
	$(MAKE) test-uncached PROJECT=$(PROJECT) NPC_CONFIG=rv32-baseline
	$(MAKE) test-uncached PROJECT=$(PROJECT) NPC_CONFIG=rv64-sequential

test-dcache: $(DCACHE_TEST_BINARY)
	$(DCACHE_TEST_BINARY)

test-dcache-configs:
	$(MAKE) test-dcache PROJECT=$(PROJECT) NPC_CONFIG=rv32-baseline
	$(MAKE) test-dcache PROJECT=$(PROJECT) NPC_CONFIG=rv64-sequential

test-core-merge: $(CORE_MERGE_TEST_BINARY)
	$(CORE_MERGE_TEST_BINARY)

test-core-merge-configs:
	$(MAKE) test-core-merge PROJECT=$(PROJECT) NPC_CONFIG=rv32-baseline
	$(MAKE) test-core-merge PROJECT=$(PROJECT) NPC_CONFIG=rv64-sequential

test-soc-width-converter: $(SOC_WIDTH_CONVERTER_TEST_BINARY)
	$(SOC_WIDTH_CONVERTER_TEST_BINARY)

test-sdram-axi: $(SDRAM_AXI_TEST_BINARY)
	$(SDRAM_AXI_TEST_BINARY)

test-axi-delayer: $(AXI_DELAYER_TEST_BINARY)
	$(AXI_DELAYER_TEST_BINARY)

test-privileged: $(PRIVILEGED_TEST_BINARY)
	$(PRIVILEGED_TEST_BINARY)

test-privileged-configs:
	$(MAKE) test-privileged PROJECT=$(PROJECT) NPC_CONFIG=rv32-baseline
	$(MAKE) test-privileged PROJECT=$(PROJECT) NPC_CONFIG=rv64-sequential

# ============================================================
# P3 RV32/RV64 functional baseline
# ============================================================

.PHONY: nemu-ref-rv32 nemu-ref-rv64
.PHONY: regression-p3-e regression-p3-f-rv32 regression-p3-f-rv64 regression-p3-g

# NEMU只有一份活动.config，因此两个reference必须顺序构建，不能写成可并行的依赖图。
nemu-ref-rv32:
	$(MAKE) -C $(NEMU_DIR) riscv32-ref_defconfig
	$(MAKE) -C $(NEMU_DIR)

nemu-ref-rv64:
	$(MAKE) -C $(NEMU_DIR) riscv64-ref_defconfig
	$(MAKE) -C $(NEMU_DIR)

regression-p3-e:
	$(MAKE) test-privileged-configs PROJECT=$(PROJECT)
	$(MAKE) test-exu-configs PROJECT=$(PROJECT)

regression-p3-f-rv32:
	$(MAKE) nemu-ref-rv32 PROJECT=$(PROJECT)
	$(MAKE) -C $(CPU_TESTS_DIR) \
		ARCH=riscv32-npc \
		NPC_RUN_TARGET=sim-difftest \
		REF=$(RV32_NEMU_REF) \
		ALL="$(P3_CPU_TESTS)" \
		run

regression-p3-f-rv64:
	$(MAKE) nemu-ref-rv64 PROJECT=$(PROJECT)
	$(MAKE) -C $(CPU_TESTS_DIR) \
		ARCH=riscv64-npc \
		NPC_RUN_TARGET=sim-difftest \
		REF=$(RV64_NEMU_REF) \
		ALL="$(P3_CPU_TESTS)" \
		run

# 每一步使用递归make显式串行执行。失败会立即停止，保留第一个失效边界的日志。
regression-p3-g:
	$(MAKE) test-configs PROJECT=$(PROJECT)
	$(MAKE) test-idu-configs PROJECT=$(PROJECT)
	$(MAKE) test-exu-configs PROJECT=$(PROJECT)
	$(MAKE) test-lsu-configs PROJECT=$(PROJECT)
	$(MAKE) test-pipeline-configs PROJECT=$(PROJECT)
	$(MAKE) test-uncached-configs PROJECT=$(PROJECT)
	$(MAKE) test-privileged-configs PROJECT=$(PROJECT)
	$(MAKE) test-soc-width-converter PROJECT=$(PROJECT) NPC_CONFIG=rv64-sequential
	$(MAKE) lint-configs PROJECT=$(PROJECT)
	$(MAKE) lint-soc PROJECT=$(PROJECT) NPC_CONFIG=rv64-sequential
	$(MAKE) build-npc PROJECT=$(PROJECT) NPC_CONFIG=rv32-baseline
	$(MAKE) build-npc PROJECT=$(PROJECT) NPC_CONFIG=rv64-sequential
	$(MAKE) regression-p3-f-rv32 PROJECT=$(PROJECT)
	$(MAKE) regression-p3-f-rv64 PROJECT=$(PROJECT)
	$(MAKE) sta-configs PROJECT=$(PROJECT)

# ============================================================
# Simulation entry points
# ============================================================

.PHONY: sim sim-npc sim-soc sim-am sim-image

# Keep `make sim` as the current full-system default.
sim: sim-soc

sim-npc: $(NPC_SIM_BINARY)
	@test -n "$(strip $(IMG))" || (echo "IMG is required"; exit 1)
	@echo "NPC: standalone image = $(IMG)"
	$(NPC_SIM_BINARY) $(SIM_ARGS) $(IMG)

sim-soc: $(SOC_SIM_BINARY)
	@test -n "$(strip $(IMG)$(FLASH_IMG))" || \
		(echo "IMG or FLASH_IMG is required"; exit 1)
	@echo "NPC: SoC MROM image  = $(IMG)"
	@echo "NPC: SoC flash image = $(FLASH_IMG)"
	$(SOC_SIM_BINARY) $(SIM_ARGS) \
		$(if $(FLASH_IMG),--flash $(FLASH_IMG)) \
		$(IMG)

# Compatibility entry points used by Abstract Machine platform makefiles.
sim-am: sim-npc
sim-image: sim-soc

.PHONY: sim-itrace sim-mtrace sim-ftrace sim-trace
.PHONY: sim-difftest sim-wave sim-debug

sim-itrace: $(NPC_SIM_BINARY)
	@test -n "$(strip $(IMG))" || (echo "IMG is required"; exit 1)
	$(NPC_SIM_BINARY) --itrace $(IMG)

sim-mtrace: $(NPC_SIM_BINARY)
	@test -n "$(strip $(IMG))" || (echo "IMG is required"; exit 1)
	$(NPC_SIM_BINARY) --mtrace $(IMG)

sim-ftrace: $(NPC_SIM_BINARY)
	@test -n "$(strip $(IMG))" || (echo "IMG is required"; exit 1)
	@test -n "$(strip $(ELF))" || (echo "ELF is required"; exit 1)
	$(NPC_SIM_BINARY) --ftrace --elf $(ELF) $(IMG)

sim-trace: $(NPC_SIM_BINARY)
	@test -n "$(strip $(IMG))" || (echo "IMG is required"; exit 1)
	$(NPC_SIM_BINARY) --itrace --mtrace $(IMG)

sim-difftest: $(NPC_SIM_BINARY)
	@test -n "$(strip $(IMG))" || (echo "IMG is required"; exit 1)
	@test -n "$(strip $(REF))" || (echo "REF is required"; exit 1)
	$(NPC_SIM_BINARY) --batch --diff $(REF) $(IMG)

sim-wave: $(NPC_SIM_BINARY)
	@test -n "$(strip $(IMG))" || (echo "IMG is required"; exit 1)
	$(NPC_SIM_BINARY) --trace $(IMG)
	gtkwave waveform.vcd

sim-debug: $(NPC_SIM_BINARY)
	@test -n "$(strip $(IMG))" || (echo "IMG is required"; exit 1)
	$(NPC_SIM_BINARY) --trace --itrace --mtrace $(IMG)
	gtkwave waveform.vcd

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

CACHE_TRACE_ARCH             ?= riscv32-nemu
CACHE_TRACE_ISA              = $(if $(filter riscv64-nemu,$(CACHE_TRACE_ARCH)),riscv64,riscv32)
CACHE_TRACE_IMAGE            ?= $(CPU_TESTS_DIR)/build/bubble-sort-$(CACHE_TRACE_ISA)-npc.bin
CACHE_TRACE_FILE             ?= $(abspath ./result/cache/$(CACHE_TRACE_ISA)_nemu_pc_trace.bin)
CACHE_TRACE_IMAGE_PATH       = $(abspath $(CACHE_TRACE_IMAGE))
CACHE_TRACE_PATH             = $(abspath $(CACHE_TRACE_FILE))
CACHE_CAPACITY_BYTES         ?= $(NPC_ICACHE_CAPACITY_BYTES)
CACHE_LINE_BYTES             ?= $(NPC_ICACHE_LINE_BYTES)
CACHE_WAYS                   ?= $(NPC_ICACHE_WAY_COUNT)
# 当前RTL在命中时从lookup握手到响应握手需要1周期。
CACHE_HIT_TIME_CYCLES        ?= 1
# 保持fixed作为默认值，使原有cachesim命令继续复现历史基线。independent和burst
# 必须显式选择，避免把不同时间模型产生的AMAT/TMT放在同一张表中直接比较。
CACHE_REFILL_MODEL           ?= fixed
CACHE_REFILL_BEAT_BYTES      ?= 4
# a/b/c/d默认各取1周期，只用于比较独立事务和burst的结构差异。实际周期结论必须用
# RTL PMU测得的critical-response与complete-refill延迟校准这四项参数。
CACHE_READ_ADDRESS_CYCLES    ?= 1
CACHE_MEMORY_COMMAND_CYCLES  ?= 1
CACHE_FIRST_DATA_CYCLES      ?= 1
CACHE_RESPONSE_BEAT_CYCLES   ?= 1
# 下面两个默认值只保留用于复现早期8B line/PSRAM历史模型。当前128B/16B/SDRAM配置
# 必须通过校准CSV或RTL PMU实测，不能把历史值当成当前缺失代价。
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
# B4 cache评估必须经过AXI SDRAM路径，才能测量AXI burst和AXI delayer的真实效果。
ICACHE_CALIBRATION_ARCH           ?= riscv32-ysyxsoc-sdram
ICACHE_CALIBRATION_CAPACITY_BYTES ?= $(NPC_ICACHE_CAPACITY_BYTES)
ICACHE_CALIBRATION_WAY_COUNT      ?= $(NPC_ICACHE_WAY_COUNT)
ICACHE_CALIBRATION_MEMORY_NAME     = $(patsubst riscv32-ysyxsoc-%,%,$(ICACHE_CALIBRATION_ARCH))
ICACHE_CALIBRATION_OUTPUT         ?= $(abspath ./result/cache/rtl_icache_penalty_rv32_$(ICACHE_CALIBRATION_MEMORY_NAME)_$(ICACHE_CALIBRATION_SCALE).csv)

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
	@test "$(CACHE_TRACE_ARCH)" = "riscv32-nemu" -o \
	      "$(CACHE_TRACE_ARCH)" = "riscv64-nemu" || \
		(echo "CACHE_TRACE_ARCH must be riscv32-nemu or riscv64-nemu"; exit 1)
	@test -f "$(CACHE_TRACE_IMAGE_PATH)" || \
		(echo "trace image not found: $(CACHE_TRACE_IMAGE_PATH)"; exit 1)
	mkdir -p $(dir $(CACHE_TRACE_PATH))
	$(MAKE) -C $(NEMU_DIR) \
		$(if $(filter riscv64-nemu,$(CACHE_TRACE_ARCH)),riscv64-cachesim_defconfig,riscv32-cachesim_defconfig)
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

# 在同一RV32 ysyxSoC存储环境中逐项重编译并运行MicroBench，从RTL PMU提取关键字
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
DCACHE_TRACE_ARCH       ?= riscv32-nemu
DCACHE_TRACE_ISA        = $(if $(filter riscv64-nemu,$(DCACHE_TRACE_ARCH)),riscv64,riscv32)
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
DCACHE_REFILL_BEAT_BYTES ?= 4
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
	@test "$(DCACHE_TRACE_ARCH)" = "riscv32-nemu" -o \
	      "$(DCACHE_TRACE_ARCH)" = "riscv64-nemu" || \
		(echo "DCACHE_TRACE_ARCH must be riscv32-nemu or riscv64-nemu"; exit 1)
	$(MAKE) -C $(NEMU_DIR) \
		$(if $(filter riscv64-nemu,$(DCACHE_TRACE_ARCH)),riscv64-cachesim_defconfig,riscv32-cachesim_defconfig)
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
BRANCH_TRACE_ARCH       ?= riscv32-nemu
BRANCH_TRACE_ISA        = $(if $(filter riscv64-nemu,$(BRANCH_TRACE_ARCH)),riscv64,riscv32)
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
	@test "$(BRANCH_TRACE_ARCH)" = "riscv32-nemu" -o \
	      "$(BRANCH_TRACE_ARCH)" = "riscv64-nemu" || \
		(echo "BRANCH_TRACE_ARCH must be riscv32-nemu or riscv64-nemu"; exit 1)
	$(MAKE) -C $(NEMU_DIR) \
		$(if $(filter riscv64-nemu,$(BRANCH_TRACE_ARCH)),riscv64-cachesim_defconfig,riscv32-cachesim_defconfig)
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

# 正式性能基线使用AXI SDRAM。PSRAM只用于独立的外设和启动流程验证。
PERF_ARCH             ?= riscv32-ysyxsoc-sdram
PERF_SCALE            ?= train
PERF_MICROBENCH_DIR   := $(MICROBENCH_DIR)
PERF_MICROBENCH_IMAGE := $(PERF_MICROBENCH_DIR)/build/microbench-$(PERF_ARCH).bin
PERF_DESCRIPTION      ?=
PERF_FREQUENCY_MHZ    ?=
PERF_STA_REPORT       ?=
PERF_RESULTS_TABLE    ?= $(abspath ./result/performance/README.md)
PERF_RECORD_SCRIPT    := $(abspath ./scripts/record_performance.py)

.PHONY: perf perf-record
perf: $(SOC_SIM_BINARY)
	$(MAKE) -C $(PERF_MICROBENCH_DIR) ARCH=$(PERF_ARCH) clean
	$(MAKE) -C $(PERF_MICROBENCH_DIR) \
		ARCH=$(PERF_ARCH) \
		mainargs=$(PERF_SCALE) \
		image
	@echo "NPC commit        = $$(git -C $(abspath ..) rev-parse HEAD)"
	@echo "AM-kernels commit = $$(git -C $(PERF_MICROBENCH_DIR) rev-parse HEAD)"
	@echo "Benchmark scale   = $(PERF_SCALE)"
	@echo "Timing mode       = $(if $(strip $(NPC_SIM_CPU_FREQ_MHZ)),CPU $(NPC_SIM_CPU_FREQ_MHZ) MHz / device 100 MHz; CLINT and delay ratio configured together,legacy: CLINT CPU 100 MHz; delay ratio 3037/1024; not calibrated to STA)"
	@echo "Benchmark image   = $(PERF_MICROBENCH_IMAGE)"
	$(SOC_SIM_BINARY) --batch --flash $(PERF_MICROBENCH_IMAGE)

perf-record:
	@test -n "$(strip $(PERF_DESCRIPTION))" || \
		(echo "PERF_DESCRIPTION is required"; exit 1)
	@test -n "$(strip $(PERF_FREQUENCY_MHZ)$(PERF_STA_REPORT))" || \
		(echo "PERF_FREQUENCY_MHZ or PERF_STA_REPORT is required"; exit 1)
	@test -z "$(strip $(PERF_FREQUENCY_MHZ))" -o -z "$(strip $(PERF_STA_REPORT))" || \
		(echo "Set only one of PERF_FREQUENCY_MHZ and PERF_STA_REPORT"; exit 1)
	python3 $(PERF_RECORD_SCRIPT) \
		--npc-dir $(abspath .) \
		--workspace-root $(abspath ..) \
		--am-dir $(PERF_MICROBENCH_DIR) \
		--scale $(PERF_SCALE) \
		--description "$(PERF_DESCRIPTION)" \
		--table $(PERF_RESULTS_TABLE) \
		$(if $(PERF_FREQUENCY_MHZ),--frequency-mhz $(PERF_FREQUENCY_MHZ)) \
		$(if $(PERF_STA_REPORT),--sta-report $(abspath $(PERF_STA_REPORT)))

# ============================================================
# Static checks and maintenance
# ============================================================

.PHONY: lint lint-npc lint-soc lint-configs sta sta-configs clean
lint: lint-npc

lint-npc: $(RTL_FILELIST)
	$(call git_commit, "sim RTL") # DO NOT REMOVE THIS LINE!!!
	$(VERILATOR) --lint-only -Wall -Wno-fatal \
		$(NPC_CONFIG_DEFINE) \
		--top-module $(NPC_TOP_MODULE) \
		-f $(RTL_FILELIST)

lint-soc: $(RTL_FILELIST) $(SOC_VERILOG_SOURCES)
	$(call git_commit, "sim RTL") # DO NOT REMOVE THIS LINE!!!
	$(VERILATOR) --lint-only -Wall -Wno-fatal \
		$(NPC_CONFIG_DEFINE) \
		$(SOC_RTL_INCLUDE_FLAGS) \
		--top-module $(SOC_TOP_MODULE) \
		-f $(RTL_FILELIST) \
		$(SOC_VERILOG_SOURCES)

lint-configs:
	$(MAKE) lint-npc PROJECT=$(PROJECT) NPC_CONFIG=rv32-course-area
	$(MAKE) lint-npc PROJECT=$(PROJECT) NPC_CONFIG=rv32-baseline
	$(MAKE) lint-npc PROJECT=$(PROJECT) NPC_CONFIG=rv64-sequential

# 课程面积目标统计纯core，并把当前小容量I-cache的tag/data阵列完整映射为标准单元。
# system wrapper、仿真内存和外设不属于手册的NPC面积口径。
STA_TOOL_DIR      := $(abspath ../yosys-sta)
STA_DESIGN        := riscv32_core
STA_FREQUENCY_MHZ ?= 300
STA_SYNTH_STRATEGY ?= DELAY 0
STA_RUN_POWER_ANALYSIS ?= 0
STA_SDC_FILE      := $(abspath ./constr/riscv32_npc_axi.sdc)
STA_PDK           ?= nangate45
STA_OUTPUT_ROOT   := $(abspath ./result/sta/$(STA_PDK)-$(NPC_CONFIG)-icache-$(NPC_ICACHE_CAPACITY_BYTES)b-way-$(NPC_ICACHE_WAY_COUNT)-line-$(NPC_ICACHE_LINE_BYTES)b-$(DCACHE_BUILD_TAG)-$(PREDICTOR_BUILD_TAG))

sta: $(STA_RTL_FILELIST) $(STA_RTL_DEPENDENCIES) $(STA_SDC_FILE)
	NPC_STA_NETLIST_FILE="$(STA_OUTPUT_ROOT)/$(STA_DESIGN)-$(STA_FREQUENCY_MHZ)MHz/$(STA_DESIGN).netlist.v" $(MAKE) -C $(STA_TOOL_DIR) sta \
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

sta-configs:
	$(MAKE) sta PROJECT=$(PROJECT) NPC_CONFIG=rv32-course-area
	$(MAKE) sta PROJECT=$(PROJECT) NPC_CONFIG=rv32-baseline
	$(MAKE) sta PROJECT=$(PROJECT) NPC_CONFIG=rv64-sequential

clean:
	rm -rf ./build wave.vcd waveform.vcd

# ysyx tracing helper and workspace-level variables.
include ../Makefile

-include $(wildcard $(NPC_OBJ_DIR)/*.d)
-include $(wildcard $(SOC_OBJ_DIR)/*.d)
-include $(wildcard $(NVBOARD_OBJ_DIR)/*.d)

.PHONY: help
help:
	@echo "Usage: make <target> PROJECT=riscv32 NPC_CONFIG=<config> [IMG=...]"
	@echo "Configs: $(SUPPORTED_NPC_CONFIGS)"
	@echo ""
	@echo "Build targets:"
	@echo "  build-npc     Build the fast standalone NPC simulator"
	@echo "  build-soc     Build ysyxSoC; RV64 uses the AXI64-to-AXI32 boundary converter"
	@echo "  test-configs  Check both static configuration contracts"
	@echo "  test-idu-configs  Run directed IDU tests for RV32 and RV64"
	@echo "  test-exu-configs  Run directed EXU tests for RV32 and RV64"
	@echo "  test-lsu-configs  Run directed LSU tests for RV32 and RV64"
	@echo "  test-pipeline-configs  Test pipeline registers, hazards, and redirects"
	@echo "  test-uncached-configs  Run uncached AXI4 tests for RV32 and RV64"
	@echo "  test-dcache-configs  Test D-cache hit, refill, writeback, and clean in RV32/RV64"
	@echo "  test-core-merge-configs  Test I/D shared AXI read arbitration in RV32/RV64"
	@echo "  test-soc-width-converter  Test RV64 AXI to ysyxSoC AXI32 conversion"
	@echo "  test-sdram-axi  Test AXI transaction classification and native SDRAM BL8 reads"
	@echo "  test-axi-delayer  Test per-beat AXI read timing and independent write timing"
	@echo "  test-privileged-configs  Test CSR, trap, commit, and PMU semantics in RV32/RV64"
	@echo "  nemu-ref-rv32 / nemu-ref-rv64  Build the matching standalone DiffTest reference"
	@echo "  regression-p3-e  Run RV32/RV64 privileged directed tests"
	@echo "  regression-p3-f-rv32 / regression-p3-f-rv64  Run 35 CPU/exception DiffTests"
	@echo "  regression-p3-g  Run the complete sequential dual-configuration baseline"
	@echo ""
	@echo "Run targets:"
	@echo "  sim-npc       Run standalone NPC; requires IMG"
	@echo "  sim-soc       Run ysyxSoC; requires IMG and/or FLASH_IMG"
	@echo "  sim           Alias of sim-soc"
	@echo "  sim-am        AM compatibility alias of sim-npc"
	@echo "  sim-image     ysyxSoC AM compatibility alias of sim-soc"
	@echo "  nvboard       Run ysyxSoC with NVBoard"
	@echo ""
	@echo "Debug targets use the faster standalone NPC:"
	@echo "  sim-itrace sim-mtrace sim-ftrace sim-trace"
	@echo "  sim-difftest sim-wave sim-debug"
	@echo ""
	@echo "Evaluation targets:"
	@echo "  perf          Run MicroBench on ysyxSoC"
	@echo "  perf-record   Run and append a reproducible performance record"
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
	@echo "  lint-configs  Lint both formal NPC configurations"
	@echo "  sta / sta-configs  Run 300 MHz synthesis and STA for one/both NPC configurations"
	@echo ""
	@echo "Examples:"
	@echo "  make lint-npc NPC_CONFIG=rv64-sequential"
	@echo "  make lint-npc NPC_CONFIG=rv64-sequential NPC_ICACHE_LINE_BYTES=64"
	@echo "  make sim-npc NPC_CONFIG=rv32-baseline IMG=path/to/riscv32-npc.bin"
	@echo "  make sim-soc NPC_CONFIG=rv32-baseline FLASH_IMG=path/to/riscv32-ysyxsoc.bin"

.PHONY: test-timer-interrupt
test-timer-interrupt:
	@test "$(NPC_CONFIG)" = rv32-baseline || (echo "Use NPC_CONFIG=rv32-baseline"; exit 1)
	python3 tests/interrupt/run.py $(NPC_CONFIG_DEFINE)

.PHONY: test-precise-exception
EXCEPTION_TEST_OUTPUT ?= $(abspath ./build/tests/exception)
test-precise-exception:
	@test "$(NPC_CONFIG)" = rv32-baseline || (echo "Use NPC_CONFIG=rv32-baseline"; exit 1)
	python3 tests/exception/run.py --output "$(EXCEPTION_TEST_OUTPUT)" $(NPC_CONFIG_DEFINE)


# 包含实际复位控制器的纯核边界；保留未缓冲网表，再生成受限扇出的复位树。
STA_RESET_OUTPUT_DIR ?= $(STA_OUTPUT_ROOT)/riscv32_core_reset_boundary-$(STA_FREQUENCY_MHZ)MHz-buffered
.PHONY: sta-reset
sta-reset:
	@test "$(STA_PDK)" = nangate45 || (echo "Reset buffer mapping currently supports NanGate45"; exit 1)
	$(MAKE) sta STA_DESIGN=riscv32_core_reset_boundary \
		STA_SDC_FILE=$(abspath ./constr/riscv32_core_reset_boundary.sdc)
	python3 scripts/build_reset_tree.py \
		--netlist $(STA_OUTPUT_ROOT)/riscv32_core_reset_boundary-$(STA_FREQUENCY_MHZ)MHz/riscv32_core_reset_boundary.netlist.v \
		--liberty $(STA_TOOL_DIR)/pdk/nangate45/lib/Nangate45_typ.lib \
		--output-dir $(STA_RESET_OUTPUT_DIR)
	python3 scripts/check_reset_netlist.py $(STA_RESET_OUTPUT_DIR)/buffered.json \
		--output $(STA_RESET_OUTPUT_DIR)/reset-connectivity.json
	cp constr/riscv32_core_reset_boundary.sdc $(STA_RESET_OUTPUT_DIR)/constraints.sdc
	NPC_STA_NETLIST_FILE=$(STA_RESET_OUTPUT_DIR)/riscv32_core_reset_boundary.netlist.v \
		CLK_FREQ_MHZ=$(STA_FREQUENCY_MHZ) RUN_POWER_ANALYSIS=0 \
		$(STA_TOOL_DIR)/bin/iEDA -script $(STA_TOOL_DIR)/scripts/sta.tcl \
		$(STA_RESET_OUTPUT_DIR)/constraints.sdc \
		$(STA_RESET_OUTPUT_DIR)/riscv32_core_reset_boundary.netlist.v \
		riscv32_core_reset_boundary nangate45 > $(STA_RESET_OUTPUT_DIR)/sta.log 2>&1

.PHONY: test-timing
test-timing:
	python3 tests/timing/run.py $(NPC_CONFIG_DEFINE)

.PHONY: test-issue-window
test-issue-window:
	python3 tests/hardware-optimization/run_monitor.py $(NPC_CONFIG_DEFINE)
