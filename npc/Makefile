# path

PROJECT ?= riscv32
TOPNAME = ysyxSoCFull

INC_PATH ?=
INC_PATH += $(abspath ./include)

CAPSTONE_HOME ?= $(abspath ../nemu/tools/capstone/repo)
CAPSTONE_INC  ?= $(CAPSTONE_HOME)/include
CAPSTONE_LIB  ?= $(CAPSTONE_HOME)

INC_PATH += $(CAPSTONE_INC)

BUILD_DIR = ./build/$(PROJECT)

OBJ_DIR_SIM = $(BUILD_DIR)/obj_dir_sim
OBJ_DIR_NV  = $(BUILD_DIR)/obj_dir_nv

BIN_SIM = $(BUILD_DIR)/$(TOPNAME)_sim
BIN_NV  = $(BUILD_DIR)/$(TOPNAME)_nvboard

IMG ?=
FLASH_IMG ?=
SIM_ARGS ?= --batch

# verilator config
VERILATOR = verilator
VERILATOR_FLAGS += -MMD --build -cc -Wall -Wno-fatal \
					-O3 --x-assign fast --x-initial fast --trace --autoflush

# make build directory
$(shell mkdir -p $(BUILD_DIR))

# RTL project source
# NPC
VSRC_DIR  = $(abspath ./vsrc/$(PROJECT))
VSRC_LIST ?= $(VSRC_DIR)/filelist/filelist.f
# The simulation filelist is also documentation for staged RTL TODOs. Only source entries
# participate in Make dependencies; Verilator still reads the complete filelist.
VSRC_DEPS = $(shell sed -e 's|$${NPC_HOME}|$(abspath .)|g' \
	-e '/^[[:space:]]*\/\//d' -e '/^[[:space:]]*$$/d' $(VSRC_LIST))

# SOC
YSYXSOC_HOME := $(abspath ../ysyxSoC)
YSYXSOC_PERIP_DIR := $(YSYXSOC_HOME)/perip
YSYXSOC_FULL_V := $(YSYXSOC_HOME)/build/ysyxSoCFull.v
# Select all available file
YSYXSOC_VSRCS := $(shell find $(YSYXSOC_PERIP_DIR) -type f -name "*.v" | sort)
YSYXSOC_VSRCS += $(YSYXSOC_FULL_V)
# verilog `include search path
VERILATOR_RTL_INCLUDES := \
	-I$(YSYXSOC_PERIP_DIR)/uart16550/rtl \
	-I$(YSYXSOC_PERIP_DIR)/spi/rtl



# normal simulation C/C++ sources
CSRC_SIM = $(shell find $(abspath ./csrc) -type f \( -name "*.c" -o -name "*.cc" -o -name "*.cpp" \))

# NVBoard simulation C/C++ sources
CSRC_NV = $(shell find $(abspath ./csrc) -type f \( -name "*.c" -o -name "*.cc" -o -name "*.cpp" \))

# NVBoard auto bind source
NXDC_FILES = constr/top.nxdc
SRC_AUTO_BIND = $(abspath $(BUILD_DIR)/auto_bind.cpp)
$(SRC_AUTO_BIND): $(NXDC_FILES)
	python3 $(NVBOARD_HOME)/scripts/auto_pin_bind.py $^ $@
CSRC_NV += $(SRC_AUTO_BIND)
include $(NVBOARD_HOME)/scripts/nvboard.mk

# include flags
INCFLAGS = $(addprefix -I, $(INC_PATH))
# common C++ flags
CXXFLAGS_COMMON := $(INCFLAGS) \
	-DTOP_CLASS=V$(TOPNAME) \
	-DTOP_CLOCK=clock \
	-DTOP_RESET=reset \
	-DTOP_RESET_ACTIVE_LEVEL=1
LDFLAGS_COMMON := -L$(CAPSTONE_LIB) -Wl,-rpath=$(CAPSTONE_LIB) -lcapstone -ldl

# normal sim does not enable NVBoard
CXXFLAGS_SIM := $(CXXFLAGS_COMMON)
# nvboard build enables CONFIG_NVBOARD
CXXFLAGS_NV := $(CXXFLAGS_COMMON) -DCONFIG_NVBOARD


# make sim
$(BIN_SIM): $(VSRC_LIST) $(VSRC_DEPS) $(YSYXSOC_VSRCS) $(CSRC_SIM)
	$(call git_commit, "sim RTL") # DO NOT REMOVE THIS LINE!!!
	$(VERILATOR) $(VERILATOR_FLAGS) \
		$(VERILATOR_RTL_INCLUDES) \
		--top-module $(TOPNAME) \
		-f $(VSRC_LIST) \
		$(YSYXSOC_VSRCS) \
		$(CSRC_SIM) \
		$(addprefix -CFLAGS , $(CXXFLAGS_SIM)) \
		$(addprefix -LDFLAGS , $(LDFLAGS_COMMON)) \
		--Mdir $(OBJ_DIR_SIM) \
		--exe \
		-o $(abspath $(BIN_SIM)) \
		--timescale "1ns/1ns" \
		--no-timing


# make nvboard
$(BIN_NV): $(VSRC_LIST) $(VSRC_DEPS) $(YSYXSOC_VSRCS) $(CSRC_NV) $(NVBOARD_ARCHIVE)
	$(call git_commit, "sim nvboard") # DO NOT REMOVE THIS LINE!!!
	$(VERILATOR) $(VERILATOR_FLAGS) \
		$(VERILATOR_RTL_INCLUDES) \
		--top-module $(TOPNAME) \
		-f $(VSRC_LIST) \
		$(YSYXSOC_VSRCS) \
		$(CSRC_NV) \
		$(NVBOARD_ARCHIVE) \
		$(addprefix -CFLAGS , $(CXXFLAGS_NV)) \
		$(addprefix -LDFLAGS , $(LDFLAGS_COMMON) $(LDFLAGS)) \
		--Mdir $(OBJ_DIR_NV) \
		--exe \
		-o $(abspath $(BIN_NV)) \
		--timescale "1ns/1ns" \
		--no-timing


sim: $(BIN_SIM)
	$(BIN_SIM)

sim-image: $(BIN_SIM)
	@test -n "$(strip $(IMG)$(FLASH_IMG))" || \
		(echo "IMG or FLASH_IMG is required"; exit 1)
	@echo "NPC: MROM image  = $(IMG)"
	@echo "NPC: Flash image = $(FLASH_IMG)"
	$(BIN_SIM) $(SIM_ARGS) \
		$(if $(FLASH_IMG),--flash $(FLASH_IMG)) \
		$(IMG)

sim-am: sim-image

sim-itrace: $(BIN_SIM)
	@echo "NPC: Running AM program with itrace $(IMG)..."
	$(BIN_SIM) --itrace $(IMG)

sim-mtrace: $(BIN_SIM)
	@echo "NPC: Running AM program with mtrace $(IMG)..."
	$(BIN_SIM) --mtrace $(IMG)

sim-ftrace: $(BIN_SIM)
	@echo "NPC: Running AM program with ftrace IMG=$(IMG) ELF=$(ELF)..."
	@test -n "$(ELF)" || (echo "ELF is required for ftrace"; exit 1)
	$(BIN_SIM) --ftrace --elf $(ELF) $(IMG)

sim-trace: $(BIN_SIM)
	@echo "NPC: Running AM program with itrace + mtrace $(IMG)..."
	$(BIN_SIM) --itrace --mtrace $(IMG)

sim-difftest: $(BIN_SIM)
	@echo "NPC: Running AM program with DiffTest IMG=$(IMG) REF=$(REF)..."
	@test -n "$(REF)" || (echo "REF is required for DiffTest"; exit 1)
	$(BIN_SIM) --batch --diff $(REF) $(IMG)

sim-wave: $(BIN_SIM)
	@echo "NPC: Running AM program with waveform $(IMG)..."
	$(BIN_SIM) --trace $(IMG)
	gtkwave waveform.vcd

sim-debug: $(BIN_SIM)
	@echo "NPC: Running AM program with waveform + itrace + mtrace $(IMG)..."
	$(BIN_SIM) --trace --itrace --mtrace $(IMG)
	gtkwave waveform.vcd

nvboard: $(BIN_NV)
	$(BIN_NV) --nvboard $(IMG)

lint: $(VSRC_LIST)
	$(call git_commit, "sim RTL") # DO NOT REMOVE THIS LINE!!!
	$(VERILATOR) --lint-only -Wall -Wno-fatal \
	$(VERILATOR_RTL_INCLUDES) \
	--top-module $(TOPNAME) \
	-f $(VSRC_LIST) \
	$(YSYXSOC_VSRCS)

clean:
	rm -rf ./build wave.vcd waveform.vcd


include ../Makefile

-include $(wildcard $(OBJ_DIR_SIM)/*.d)
-include $(wildcard $(OBJ_DIR_NV)/*.d)


.PHONY: help
help:
	@echo "Usage:"
	@echo "  make [Target] PROJECT=[Folder] IMG=[bin] FLASH_IMG=[bin]"
	@echo ""
	@echo "Targets:"
	@echo "  sim        Compile and run simulation without image"
	@echo "  sim-image  Run with an optional MROM image and/or Flash image"
	@echo "  sim-am     Compatibility alias of sim-image"
	@echo "  sim-wave   Compile, run with --trace, and open GTKWave"
	@echo "  sim-itrace Compile and run with itrace"
	@echo "  sim-mtrace Compile and run with mtrace"
	@echo "  sim-ftrace Compile and run with ftrace, requires ELF=xxx.elf"
	@echo "  sim-debug  Compile and run with waveform + itrace"
	@echo "  nvboard    Compile and run with NVBoard"
	@echo "  lint       Run Verilator lint check"
	@echo "  clean      Remove build directory and temporary files"
	@echo ""
	@echo "Examples:"
	@echo "  make sim PROJECT=riscv32"
	@echo "  make sim-image PROJECT=riscv32 IMG=path/to/mrom.bin"
	@echo "  make sim-image PROJECT=riscv32 FLASH_IMG=path/to/flash.bin"
	@echo "  make sim-image PROJECT=riscv32 IMG=path/to/boot.bin FLASH_IMG=path/to/payload.bin"
	@echo "  make sim-wave PROJECT=riscv32 IMG=path/to/program.bin"
	@echo "  make nvboard PROJECT=riscv32 IMG=path/to/program.bin"
	@echo "  make sim PROJECT=experiment"
	@echo "  make sim-itrace PROJECT=riscv32 IMG=path/to/program.bin"
	@echo "  make sim-mtrace PROJECT=riscv32 IMG=path/to/program.bin"
	@echo "  make sim-ftrace PROJECT=riscv32 IMG=path/to/program.bin ELF=path/to/program.elf"
	@echo "  make sim-debug PROJECT=riscv32 IMG=path/to/program.bin"
	@echo "  sim-difftest Compile and run with DiffTest, requires REF=xxx-so"
	@echo "  make sim-difftest PROJECT=riscv32 IMG=path/to/program.bin REF=path/to/riscv32-nemu-interpreter-so"


default: help

.PHONY: default sim sim-image sim-am sim-itrace sim-mtrace sim-ftrace \
	sim-debug sim-wave sim-difftest nvboard lint clean help
