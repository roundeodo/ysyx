.DEFAULT_GOAL := help

# ============================================================
# Project and build layout
# ============================================================

PROJECT ?= riscv32

SUPPORTED_NPC_CONFIGS := rv32-baseline rv64-sequential
CONFIG_FREE_GOALS     := help clean lint-configs sta-configs test-configs test-idu-configs test-exu-configs test-lsu-configs test-uncached-configs test-privileged-configs nemu-ref-rv32 nemu-ref-rv64 regression-p3-e regression-p3-f-rv32 regression-p3-f-rv64 regression-p3-g perf-record
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
NPC_CONFIG_DEFINE := +define+YSYX_RV32_BASELINE
NPC_CONFIG_CXXFLAG := -DNPC_XLEN=32
NPC_SLANG_DEFINE := -DYSYX_RV32_BASELINE
else ifeq ($(NPC_CONFIG),rv64-sequential)
NPC_CONFIG_DEFINE := +define+YSYX_RV64_SEQUENTIAL
NPC_CONFIG_CXXFLAG := -DNPC_XLEN=64
NPC_SLANG_DEFINE := -DYSYX_RV64_SEQUENTIAL
endif

NPC_TOP_MODULE := top
SOC_TOP_MODULE := ysyxSoCFull

BUILD_DIR       := $(abspath ./build/$(PROJECT)/$(NPC_CONFIG))
NPC_OBJ_DIR     := $(BUILD_DIR)/obj_dir_npc
SOC_OBJ_DIR     := $(BUILD_DIR)/obj_dir_soc
NVBOARD_OBJ_DIR := $(BUILD_DIR)/obj_dir_nvboard
CONFIG_TEST_OBJ_DIR := $(BUILD_DIR)/obj_dir_config_test
IDU_TEST_OBJ_DIR    := $(BUILD_DIR)/obj_dir_idu_test
EXU_TEST_OBJ_DIR    := $(BUILD_DIR)/obj_dir_exu_test
LSU_TEST_OBJ_DIR    := $(BUILD_DIR)/obj_dir_lsu_test
UNCACHED_TEST_OBJ_DIR := $(BUILD_DIR)/obj_dir_uncached_test
SOC_WIDTH_CONVERTER_TEST_OBJ_DIR := $(BUILD_DIR)/obj_dir_soc_width_converter_test
PRIVILEGED_TEST_OBJ_DIR := $(BUILD_DIR)/obj_dir_privileged_test

NPC_SIM_BINARY     := $(BUILD_DIR)/$(NPC_TOP_MODULE)_sim
SOC_SIM_BINARY     := $(BUILD_DIR)/$(SOC_TOP_MODULE)_sim
NVBOARD_SIM_BINARY := $(BUILD_DIR)/$(SOC_TOP_MODULE)_nvboard
CONFIG_TEST_BINARY := $(BUILD_DIR)/config_elaboration_test
IDU_TEST_BINARY    := $(BUILD_DIR)/idu_decode_test
EXU_TEST_BINARY    := $(BUILD_DIR)/exu_alu_test
LSU_TEST_BINARY    := $(BUILD_DIR)/lsu_test
UNCACHED_TEST_BINARY := $(BUILD_DIR)/uncached_axi4_test
SOC_WIDTH_CONVERTER_TEST_BINARY := $(BUILD_DIR)/soc_width_converter_test
PRIVILEGED_TEST_BINARY := $(BUILD_DIR)/privileged_test

IMG       ?=
FLASH_IMG ?=
ELF       ?=
REF       ?=
SIM_ARGS  ?= --batch

NEMU_DIR      := $(abspath ../nemu)
CPU_TESTS_DIR := $(abspath ../am-kernels/tests/cpu-tests)
RV32_NEMU_REF := $(NEMU_DIR)/build/riscv32-nemu-interpreter-so
RV64_NEMU_REF := $(NEMU_DIR)/build/riscv64-nemu-interpreter-so

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
	-O3 --x-assign fast --x-initial fast \
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
	$(RTL_DIR)/core/riscv32_idu.sv \
	$(abspath ./tests/rtl/riscv32_idu_decode_tb.sv)

EXU_TEST_SOURCES := \
	$(RTL_DIR)/common/riscv_config_pkg.sv \
	$(RTL_DIR)/common/riscv32_addr_map_pkg.sv \
	$(RTL_DIR)/common/riscv32_pkg.sv \
	$(RTL_DIR)/core/riscv32_exu.sv \
	$(abspath ./tests/rtl/riscv32_exu_alu_tb.sv)

LSU_TEST_SOURCES := \
	$(RTL_DIR)/common/riscv_config_pkg.sv \
	$(RTL_DIR)/common/riscv32_addr_map_pkg.sv \
	$(RTL_DIR)/common/riscv32_pkg.sv \
	$(RTL_DIR)/core/riscv32_lsu.sv \
	$(abspath ./tests/rtl/riscv32_lsu_tb.sv)

UNCACHED_TEST_SOURCES := \
	$(RTL_DIR)/common/riscv_config_pkg.sv \
	$(RTL_DIR)/common/riscv32_addr_map_pkg.sv \
	$(RTL_DIR)/common/riscv32_axi4_pkg.sv \
	$(RTL_DIR)/common/riscv32_pkg.sv \
	$(RTL_DIR)/core/memory/riscv32_uncached_axi4_master.sv \
	$(abspath ./tests/rtl/riscv32_uncached_axi4_master_tb.sv)

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
	$(RTL_DIR)/core/riscv32_pmu.sv \
	$(RTL_DIR)/core/riscv32_csr_file.sv \
	$(RTL_DIR)/core/riscv32_commit.sv \
	$(RTL_DIR)/core/riscv32_trap_controller.sv \
	$(abspath ./tests/rtl/riscv32_privileged_tb.sv)

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

# Fast functional environment: CPU + local AXI models, reset PC 0x8000_0000.
$(NPC_SIM_BINARY): $(RTL_FILELIST) $(RTL_DEPENDENCIES) $(SIM_CPP_SOURCES) | $(BUILD_DIR)
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
		$(SOC_VERILOG_SOURCES) $(SIM_CPP_SOURCES) | $(BUILD_DIR)
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

$(UNCACHED_TEST_BINARY): $(UNCACHED_TEST_SOURCES) | $(BUILD_DIR)
	$(VERILATOR) --binary --timing --assert -Wall -Wno-fatal -Wno-UNUSEDPARAM \
		-Wno-UNUSEDSIGNAL \
		$(NPC_CONFIG_DEFINE) \
		--top-module riscv32_uncached_axi4_master_tb \
		$(UNCACHED_TEST_SOURCES) \
		--Mdir $(UNCACHED_TEST_OBJ_DIR) \
		-o $(UNCACHED_TEST_BINARY)

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

.PHONY: build-npc build-soc test-config test-configs test-idu test-idu-configs test-exu test-exu-configs test-lsu test-lsu-configs test-uncached test-uncached-configs test-soc-width-converter test-privileged test-privileged-configs
build-npc: $(NPC_SIM_BINARY)
build-soc: $(SOC_SIM_BINARY)
test-config: $(CONFIG_TEST_BINARY)
	$(CONFIG_TEST_BINARY)

test-configs:
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

test-uncached: $(UNCACHED_TEST_BINARY)
	$(UNCACHED_TEST_BINARY)

test-uncached-configs:
	$(MAKE) test-uncached PROJECT=$(PROJECT) NPC_CONFIG=rv32-baseline
	$(MAKE) test-uncached PROJECT=$(PROJECT) NPC_CONFIG=rv64-sequential

test-soc-width-converter: $(SOC_WIDTH_CONVERTER_TEST_BINARY)
	$(SOC_WIDTH_CONVERTER_TEST_BINARY)

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
# Reproducible performance evaluation
# ============================================================

PERF_ARCH             ?= riscv32-ysyxsoc-psram
PERF_SCALE            ?= train
PERF_MICROBENCH_DIR   := $(abspath ../am-kernels/benchmarks/microbench)
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
	$(MAKE) lint-npc PROJECT=$(PROJECT) NPC_CONFIG=rv32-baseline
	$(MAKE) lint-npc PROJECT=$(PROJECT) NPC_CONFIG=rv64-sequential

# 对正式standalone系统边界做综合与STA。输出按配置隔离，避免RV32/RV64结果相互覆盖。
STA_TOOL_DIR      := $(abspath ../yosys-sta)
STA_DESIGN        := riscv32_npc_system
STA_FREQUENCY_MHZ ?= 300
STA_SYNTH_STRATEGY ?= DELAY 0
STA_RUN_POWER_ANALYSIS ?= 0
STA_SDC_FILE      := $(abspath ./constr/riscv32_npc_axi.sdc)
STA_OUTPUT_ROOT   := $(abspath ./result/sta/$(NPC_CONFIG))
# 当前PDK不提供I-cache SRAM宏及其Liberty时序模型。综合时保留array模块边界，
# 只评估core/cache controller/AXI逻辑壳，避免把8 KiB SRAM错误地展开成6万多个触发器。
# 该报告不包含SRAM访问延迟；未来必须用目标工艺的SRAM macro和.lib替换黑盒。
STA_MEMORY_BLACKBOX_FLAGS := \
	--blackboxed-module riscv32_icache_tag_array \
	--blackboxed-module riscv32_icache_data_array

sta: $(STA_RTL_FILELIST) $(STA_RTL_DEPENDENCIES) $(STA_SDC_FILE)
	$(MAKE) -C $(STA_TOOL_DIR) sta \
		NPC_HOME=$(abspath .) \
		DESIGN=$(STA_DESIGN) \
		RTL_FILES="$(STA_RTL_DEPENDENCIES)" \
		SLANG_FLAGS="$(NPC_SLANG_DEFINE) $(STA_MEMORY_BLACKBOX_FLAGS)" \
		SDC_FILE=$(STA_SDC_FILE) \
		O=$(STA_OUTPUT_ROOT) \
		CLK_FREQ_MHZ=$(STA_FREQUENCY_MHZ) \
		SYNTH_STRATEGY="$(STA_SYNTH_STRATEGY)" \
		RUN_POWER_ANALYSIS=$(STA_RUN_POWER_ANALYSIS) \
		CLK_PORT_NAME=clk_i

sta-configs:
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
	@echo "  test-uncached-configs  Run uncached AXI4 tests for RV32 and RV64"
	@echo "  test-soc-width-converter  Test RV64 AXI to ysyxSoC AXI32 conversion"
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
	@echo "  lint-npc      Lint the standalone NPC"
	@echo "  lint-soc      Lint the selected NPC configuration inside ysyxSoC"
	@echo "  lint-configs  Lint both formal NPC configurations"
	@echo "  sta / sta-configs  Run 300 MHz synthesis and STA for one/both NPC configurations"
	@echo ""
	@echo "Examples:"
	@echo "  make lint-npc NPC_CONFIG=rv64-sequential"
	@echo "  make sim-npc NPC_CONFIG=rv32-baseline IMG=path/to/riscv32-npc.bin"
	@echo "  make sim-soc NPC_CONFIG=rv32-baseline FLASH_IMG=path/to/riscv32-ysyxsoc.bin"
