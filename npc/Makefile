.DEFAULT_GOAL := help

# ============================================================
# Project and build layout
# ============================================================

PROJECT ?= riscv32

NPC_TOP_MODULE := top
SOC_TOP_MODULE := ysyxSoCFull

BUILD_DIR       := $(abspath ./build/$(PROJECT))
NPC_OBJ_DIR     := $(BUILD_DIR)/obj_dir_npc
SOC_OBJ_DIR     := $(BUILD_DIR)/obj_dir_soc
NVBOARD_OBJ_DIR := $(BUILD_DIR)/obj_dir_nvboard

NPC_SIM_BINARY     := $(BUILD_DIR)/$(NPC_TOP_MODULE)_sim
SOC_SIM_BINARY     := $(BUILD_DIR)/$(SOC_TOP_MODULE)_sim
NVBOARD_SIM_BINARY := $(BUILD_DIR)/$(SOC_TOP_MODULE)_nvboard

IMG       ?=
FLASH_IMG ?=
ELF       ?=
REF       ?=
SIM_ARGS  ?= --batch

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

SOC_HOME             := $(abspath ../ysyxSoC)
SOC_PERIPHERAL_DIR   := $(SOC_HOME)/perip
SOC_GENERATED_TOP    := $(SOC_HOME)/build/ysyxSoCFull.v
SOC_VERILOG_SOURCES  := $(if $(wildcard $(SOC_PERIPHERAL_DIR)),$(shell find $(SOC_PERIPHERAL_DIR) -type f -name "*.v" | sort))
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
	-DTOP_CLASS=V$(NPC_TOP_MODULE) \
	-DTOP_DPI_CLASS=V$(NPC_TOP_MODULE)__Dpi \
	-DTOP_CLOCK=clk \
	-DTOP_RESET=rstn \
	-DTOP_RESET_ACTIVE_LEVEL=0

SOC_CXXFLAGS := $(CXX_INCLUDE_FLAGS) \
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

.PHONY: build-npc build-soc
build-npc: $(NPC_SIM_BINARY)
build-soc: $(SOC_SIM_BINARY)

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

.PHONY: lint lint-npc lint-soc clean
lint: lint-npc

lint-npc: $(RTL_FILELIST)
	$(call git_commit, "sim RTL") # DO NOT REMOVE THIS LINE!!!
	$(VERILATOR) --lint-only -Wall -Wno-fatal \
		--top-module $(NPC_TOP_MODULE) \
		-f $(RTL_FILELIST)

lint-soc: $(RTL_FILELIST) $(SOC_VERILOG_SOURCES)
	$(call git_commit, "sim RTL") # DO NOT REMOVE THIS LINE!!!
	$(VERILATOR) --lint-only -Wall -Wno-fatal \
		$(SOC_RTL_INCLUDE_FLAGS) \
		--top-module $(SOC_TOP_MODULE) \
		-f $(RTL_FILELIST) \
		$(SOC_VERILOG_SOURCES)

clean:
	rm -rf ./build wave.vcd waveform.vcd

# ysyx tracing helper and workspace-level variables.
include ../Makefile

-include $(wildcard $(NPC_OBJ_DIR)/*.d)
-include $(wildcard $(SOC_OBJ_DIR)/*.d)
-include $(wildcard $(NVBOARD_OBJ_DIR)/*.d)

.PHONY: help
help:
	@echo "Usage: make <target> [PROJECT=riscv32] [IMG=...] [FLASH_IMG=...]"
	@echo ""
	@echo "Build targets:"
	@echo "  build-npc     Build the fast standalone NPC simulator"
	@echo "  build-soc     Build the full ysyxSoC simulator"
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
	@echo "  lint-soc      Lint the full ysyxSoC integration"
	@echo ""
	@echo "Examples:"
	@echo "  make sim-npc IMG=path/to/riscv32-npc.bin"
	@echo "  make sim-soc FLASH_IMG=path/to/riscv32-ysyxsoc.bin"
	@echo "  make sim-npc SIM_ARGS= IMG=path/to/riscv32-npc.bin"

# 独立 RV32 定时器中断回归，不依赖 SoC 生成文件或 NEMU 动态库。
.PHONY: test-timer-interrupt
test-timer-interrupt:
	python3 tests/interrupt/run.py
