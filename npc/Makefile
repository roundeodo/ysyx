TOPNAME = top
NXDC_FILES = constr/top.nxdc
BUILD_DIR = ./build

# basic
VSRC_LIST = $(abspath ./vsrc/filelist.f)
CSRC = $(abspath ./csrc/sim_main.cpp)

# nvboard
SRC_AUTO_BIND = $(BUILD_DIR)/auto_bind.cpp
NVBOARD_ARCHIVE = $(NVBOARD_HOME)/build/nvboard.a 

# verilator 
VERILATOR = verilator
VERILATOR_FLAGS += --cc --exe --build -j 0 -Wall --trace \
				   --Mdir $(BUILD_DIR)/obj_dir

$(SRC_AUTO_BIND): $(NXDC_FILES)
	@mkdir -p $(BUILD_DIR)
	python3 $(NVBOARD_HOME)/scripts/auto_pin_bind.py $^ $@
	
sim:
	$(call git_commit, "sim RTL") # DO NOT REMOVE THIS LINE!!!
	$(VERILATOR) $(VERILATOR_FLAGS) \
	   	-f $(VSRC_LIST) $(CSRC)     \
		-o $(abspath $(BUILD_DIR)/$(TOPNAME)_sim)
	$(BUILD_DIR)/$(TOPNAME)_sim

wave: sim
	gtkwave wave.vcd

SDL_CFLAGS  = $(shell sdl2-config --cflags)
SDL_LDFLAGS = $(shell sdl2-config --libs)
nvboard: CSRC += $(SRC_AUTO_BIND)
nvboard: VERILATOR_FLAGS += -CFLAGS \
	"-I$(NVBOARD_HOME)/include $(SDL_CFLAGS)" \
							-LDFLAGS "$(SDL_LDFLAGS) -lSDL2_image"

nvboard: $(SRC_AUTO_BIND) $(NVBOARD_ARCHIVE)
	$(call git_commit, "sim NVBoard")
	$(VERILATOR) $(VERILATOR_FLAGS) \
		-f $(VSRC_LIST) $(CSRC) $(NVBOARD_ARCHIVE) \
		-o $(abspath $(BUILD_DIR)/$(TOPNAME)_nvboard)
	$(BUILD_DIR)/$(TOPNAME)_nvboard

clean:
	rm -rf obj_dir wave.vcd

include ../Makefile

.PHONY: sim wave nvboard clean 
