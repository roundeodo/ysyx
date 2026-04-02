# path
TOPNAME = top
INC_PATH ?=
BUILD_DIR = ./build
OBJ_DIR = $(BUILD_DIR)/obj_dir
BIN_SIM = $(BUILD_DIR)/$(TOPNAME)_sim
BIN_NV  = $(BUILD_DIR)/$(TOPNAME)_nvboard

# verilator constr 
VERILATOR = verilator
VERILATOR_FLAGS += -MMD --build -cc -Wall  \
				-O3 --x-assign fast --x-initial fast --noassert --trace

default: sim
#make a build direction
$(shell mkdir -p $(BUILD_DIR))

# project source
VSRC_LIST = $(abspath ./vsrc/filelist.f)
CSRC_SIM = $(shell find $(abspath ./csrc) -name "*.c" -or -name "*.cc" -or -name "*.cpp")


CSRC_NV = $(shell find $(abspath ./csrc) -name "*.c" -or -name "*.cc" -or -name "*.cpp")
NXDC_FILES = constr/top.nxdc
SRC_AUTO_BIND = $(abspath $(BUILD_DIR)/auto_bind.cpp)
$(SRC_AUTO_BIND): $(NXDC_FILES)
	python3 $(NVBOARD_HOME)/scripts/auto_pin_bind.py $^ $@
CSRC_NV += $(SRC_AUTO_BIND)
include $(NVBOARD_HOME)/scripts/nvboard.mk

# make sim
$(BIN_SIM): $(VSRC_LIST) $(CSRC_SIM)
	$(call git_commit, "sim RTL") # DO NOT REMOVE THIS LINE!!!
	$(VERILATOR) $(VERILATOR_FLAGS) \
		--top-module $(TOPNAME)		\
		-f $(VSRC_LIST) $(CSRC_SIM) \
		$(addprefix -CFLAGS , $(CXXFLAGS)) \
		--Mdir $(OBJ_DIR) --exe -o $(abspath $(BIN_SIM))

#make nvboard
INCFLAGS = $(addprefix -I, $(INC_PATH))
CXXFLAGS += $(INCFLAGS) -DTOP_NAME="\"V$(TOPNAME)\""
$(BIN_NV): $(VSRC_LIST) $(CSRC_NV) $(NVBOARD_ARCHIVE)
	$(call git_commit, "sim nvboard") # DO NOT REMOVE THIS LINE!!!
	$(VERILATOR) $(VERILATOR_FLAGS) 	\
		--top-module $(TOPNAME)  		\
		-f $(VSRC_LIST) $(CSRC_NV)	$(NVBOARD_ARCHIVE)	\
		$(addprefix -CFLAGS , $(CXXFLAGS)) 				\
		$(addprefix -LDFLAGS , $(LDFLAGS)) 				\
		--Mdir $(OBJ_DIR) --exe -o $(abspath $(BIN_NV))

sim: $(BIN_SIM)
		$(BIN_SIM)

sim-wave: $(BIN_SIM)
		$(BIN_SIM)
		gtkwave wave.vcd

nvboard: $(BIN_NV)
		$(BIN_NV)

lint: $(VSRC_LIST)
	$(call git_commit, "sim RTL") # DO NOT REMOVE THIS LINE!!!
		$(VERILATOR) --lint-only -Wall --top-module $(TOPNAME) -f $(VSRC_LIST)

clean:
	rm -rf $(BUILD_DIR) wave.vcd

include ../Makefile
-include $(wildcard $(OBJ_DIR)/*.d)
.PHONY: default sim sim-wave nvboard clean 
