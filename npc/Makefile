# path

PROJECT ?= riscv32
TOPNAME = top

INC_PATH ?=
INC_PATH += $(abspath ./include)

CAPSTONE_HOME ?= $(abspath ../nemue/tools/capstone/repo)
CAPSTONE_INC  ?= $(CAPSTONE_HOME)/include
CAPSTONE_LIB  ?= $(CAPSTONE_HOME)

INC_PATH += $(CAPSTONE_INC)

BUILD_DIR = ./build/$(PROJECT)

OBJ_DIR_SIM = $(BUILD_DIR)/obj_dir_sim
OBJ_DIR_NV  = $(BUILD_DIR)/obj_dir_nv

BIN_SIM = $(BUILD_DIR)/$(TOPNAME)_sim
BIN_NV  = $(BUILD_DIR)/$(TOPNAME)_nvboard

# verilator config
VERILATOR = verilator
VERILATOR_FLAGS += -MMD --build -cc -Wall \
				-O3 --x-assign fast --x-initial fast --noassert --trace

# make build directory
$(shell mkdir -p $(BUILD_DIR))

# RTL project source
VSRC_DIR  = $(abspath ./vsrc/$(PROJECT))
VSRC_LIST = $(VSRC_DIR)/filelist.f

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
CXXFLAGS_COMMON := $(INCFLAGS) -DTOP_NAME="\"V$(TOPNAME)\""
LDFLAGS_COMMON := -L$(CAPSTONE_LIB) -Wl,-rpath=$(CAPSTONE_LIB) -lcapstone

# normal sim does not enable NVBoard
CXXFLAGS_SIM := $(CXXFLAGS_COMMON)

# nvboard build enables CONFIG_NVBOARD
CXXFLAGS_NV := $(CXXFLAGS_COMMON) -DCONFIG_NVBOARD


# make sim
$(BIN_SIM): $(VSRC_LIST) $(CSRC_SIM)
	$(call git_commit, "sim RTL") # DO NOT REMOVE THIS LINE!!!
	$(VERILATOR) $(VERILATOR_FLAGS) \
		--top-module $(TOPNAME) \
		-f $(VSRC_LIST) $(CSRC_SIM) \
		$(addprefix -CFLAGS , $(CXXFLAGS_SIM)) \
		$(addprefix -LDFLAGS , $(LDFLAGS_COMMON)) \
		--Mdir $(OBJ_DIR_SIM) --exe -o $(abspath $(BIN_SIM))


# make nvboard
$(BIN_NV): $(VSRC_LIST) $(CSRC_NV) $(NVBOARD_ARCHIVE)
	$(call git_commit, "sim nvboard") # DO NOT REMOVE THIS LINE!!!
	$(VERILATOR) $(VERILATOR_FLAGS) \
		--top-module $(TOPNAME) \
		-f $(VSRC_LIST) $(CSRC_NV) $(NVBOARD_ARCHIVE) \
		$(addprefix -CFLAGS , $(CXXFLAGS_NV)) \
		$(addprefix -LDFLAGS , $(LDFLAGS_COMMON) $(LDFLAGS)) \
		--Mdir $(OBJ_DIR_NV) --exe -o $(abspath $(BIN_NV))


sim: $(BIN_SIM)
	$(BIN_SIM)


sim-am: $(BIN_SIM)
	@echo "NPC: Running AM program $(IMG)..."
	$(BIN_SIM) $(IMG)

sim-itrace: $(BIN_SIM)

	@echo "NPC: Running AM program with itrace $(IMG)..."

	$(BIN_SIM) --itrace $(IMG)

sim-wave: $(BIN_SIM)
	@echo "NPC: Running AM program with waveform $(IMG)..."
	$(BIN_SIM) --trace $(IMG)
	gtkwave waveform.vcd

sim-debug: $(BIN_SIM)
	@echo "NPC: Running AM program with waveform and itrace $(IMG)..."
	$(BIN_SIM) --trace --itrace $(IMG)
	gtkwave waveform.vcd

nvboard: $(BIN_NV)
	$(BIN_NV) --nvboard $(IMG)


lint: $(VSRC_LIST)
	$(call git_commit, "sim RTL") # DO NOT REMOVE THIS LINE!!!
	$(VERILATOR) --lint-only -Wall --top-module $(TOPNAME) -f $(VSRC_LIST)


clean:
	rm -rf ./build wave.vcd waveform.vcd


include ../Makefile

-include $(wildcard $(OBJ_DIR_SIM)/*.d)
-include $(wildcard $(OBJ_DIR_NV)/*.d)


.PHONY: help
help:
	@echo "Usage:"
	@echo "  make [Target] PROJECT=[Folder] IMG=[bin]"
	@echo ""
	@echo "Targets:"
	@echo "  sim        Compile and run simulation without image"
	@echo "  sim-am     Compile and run AM program with IMG=xxx.bin"
	@echo "  sim-wave   Compile, run with --trace, and open GTKWave"
	@echo "  sim-itrace Compile and run with itrace"
	@echo "  sim-debug  Compile and run with waveform + itrace"
	@echo "  nvboard    Compile and run with NVBoard"
	@echo "  lint       Run Verilator lint check"
	@echo "  clean      Remove build directory and temporary files"
	@echo ""
	@echo "Examples:"
	@echo "  make sim PROJECT=riscv32"
	@echo "  make sim-am PROJECT=riscv32 IMG=path/to/program.bin"
	@echo "  make sim-wave PROJECT=riscv32 IMG=path/to/program.bin"
	@echo "  make nvboard PROJECT=riscv32 IMG=path/to/program.bin"
	@echo "  make sim PROJECT=experiment"
	@echo "  make sim-itrace PROJECT=riscv32 IMG=path/to/program.bin"
	@echo "  make sim-debug PROJECT=riscv32 IMG=path/to/program.bin"


default: help

.PHONY: default sim sim-am sim-itrace sim-wave nvboard lint clean help