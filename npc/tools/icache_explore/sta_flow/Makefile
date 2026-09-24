PROJ_PATH = $(shell pwd)
NPC_HOME ?= $(abspath ../npc)
PROJECT ?= riscv32
FILE_LIST ?= $(NPC_HOME)/vsrc/$(PROJECT)/filelist/filelist_sta.f
SHELL := /bin/bash
YOSYS ?= yosys
YOSYS_PLUGIN_FLAGS ?= -m slang
SLANG_FLAGS ?=

O ?= $(NPC_HOME)/result
DESIGN ?= $(PROJECT)_npc_system
SDC_FILE ?= $(NPC_HOME)/constr/$(DESIGN).sdc
RTL_FILES ?= $(shell cat $(FILE_LIST) | envsubst | grep -v '^\s*//' | grep -v '^\s*\#' | xargs)
export CLK_FREQ_MHZ ?= 500
export CLK_PORT_NAME ?= clk
export SYNTH_STRATEGY ?= DELAY 0
export RUN_POWER_ANALYSIS ?= 0
PDK = icsprout55

RESULT_DIR = $(O)/$(DESIGN)-$(CLK_FREQ_MHZ)MHz
SCRIPT_DIR = $(PROJ_PATH)/scripts
NETLIST_SYN_V   = $(RESULT_DIR)/$(DESIGN).netlist.v
NETLIST_STA_V   = $(NETLIST_SYN_V)
TIMING_RPT = $(RESULT_DIR)/$(DESIGN).rpt

init:
	bash -c "$$(wget -O - https://ysyx.oscc.cc/slides/resources/scripts/init-yosys-sta.sh)"
	mkdir -p pdk
	cd pdk && git clone -b ysyx --depth 1 git@github.com:openecos-projects/icsprout55-pdk.git icsprout55

syn: $(NETLIST_SYN_V)
$(NETLIST_SYN_V): $(RTL_FILES) $(SCRIPT_DIR)/yosys.tcl
	mkdir -p $(@D)
	echo tcl $(SCRIPT_DIR)/yosys.tcl $(DESIGN) $(PDK) \"$(SLANG_FLAGS) $(RTL_FILES)\" $@ | $(YOSYS) $(YOSYS_PLUGIN_FLAGS) -g -l $(@D)/yosys.log -s -

sta: $(TIMING_RPT)
$(TIMING_RPT): $(SCRIPT_DIR)/sta.tcl $(SDC_FILE) $(NETLIST_SYN_V)
	set -o pipefail && ./bin/iEDA -script $(SCRIPT_DIR)/sta.tcl $(SDC_FILE) $(NETLIST_STA_V) $(DESIGN) $(PDK) 2>&1 | tee $(RESULT_DIR)/sta.log

clean:
	-rm -rf $(O)

.PHONY: init syn sta clean
