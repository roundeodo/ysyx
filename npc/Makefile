TOPNAME = top
VSRC = $(shell find $(abspath ./vsrc) -name "*.v")
CSRC = $(shell find $(abspath ./csrc) -name "*.cpp")

VERILATOR = verilator
VERILATOR_FLAGS += --cc --exe --build -j 0 -Wall

all: sim
	
sim:
	$(call git_commit, "sim RTL") # DO NOT REMOVE THIS LINE!!!
	$(VERILATOR) $(VERILATOR_FLAGS) $(VSRC) $(CSRC)  --Mdir obj_dir --exe -o $(TOPNAME) ./obj_dir/$(TOPNAME)

wave:
	$(call git_commit, "sim_RTL") 
	$(VERILATOR) $(VERILATOR_FLAGS) --trace $(VSRC) $(CSRC)  --Mdir obj_dir --exe -o $(TOPNAME) ./obj_dir/$(TOPNAME)
	gtkwave wave.vcd

clean:
	rm -rf obj_dir wave.vcd

include ../Makefile

.PHONY: all sim wave clean
