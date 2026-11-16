# Copyright 2020 Efabless Corporation
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# NPC qualification driver, adapted from the shared yosys-sta synthesis flow.
# Keep changes local to NPC. Reuse the installed PDK configuration and binaries.
# Arguments: toolflow, design, PDK, whitespace-separated RTL/defines, netlist, MHz.
if {[llength $argv] != 6} {error "Expected toolflow, design, PDK, RTL, netlist and MHz"}
set TOOL_FLOW [file normalize [lindex $argv 0]]
set DESIGN [lindex $argv 1]
set PDK [lindex $argv 2]
set VERILOG_FILES [string map {"\"" ""} [lindex $argv 3]]
set NETLIST_SYN_V [lindex $argv 4]
set RESULT_DIR [file dirname $NETLIST_SYN_V]
set CLK_FREQ_MHZ [lindex $argv 5]
if {$CLK_FREQ_MHZ <= 0} {error "Mapping frequency must be positive"}
set CLK_PERIOD_PS [expr 1000000.0 / $CLK_FREQ_MHZ]
source [file join $TOOL_FLOW scripts common.tcl]
set LIBS [concat {*}[lmap lib $LIB_FILES {concat "-liberty" $lib}]]
set EXCLUDE_CELLS [concat {*}[lmap cell $DONT_USE_CELLS {concat "-dont_use" $cell}]]
file mkdir $RESULT_DIR
set sdc_file [file join $RESULT_DIR abc.sdc]
set channel [open $sdc_file w]
puts $channel "set_driving_cell $BUF_CELL"
# ABC constr uses femtofarads. Include the qualification output load during
# mapping so that external interface drivers are sized for the actual budget.
puts $channel "set_load 10.0"
close $channel

# {D} is expanded by yosys abc -D. Every timing optimization receives the target.
# Map large arithmetic units independently, then flatten the mapped cells.
# This preserves their timing boundary without adding registers or retiming.
set strategy_script "+strash;balance;dch;map {D} -B 0.9;topo;stime -c;buffer -c -N 24;upsize -c {D};dnsize -c {D};stime -p;print_stats -m"
yosys -import
read_slang --keep-hierarchy --top $DESIGN --ignore-assertions {*}$VERILOG_FILES
# Slang specializes module names with their instance scope after a dollar sign.
setattr -set keep_hierarchy 1 t:riscv_multiplier* t:riscv_divider*
if {$DESIGN eq "riscv_core_reset_boundary"} {
  select -assert-count 1 t:riscv_multiplier*
  select -assert-count 1 t:riscv_divider*
}
synth -top $DESIGN -flatten -run :fine
share
onehot
muxpack
opt_demorgan
opt_ffinv
# Keep arithmetic gate topology until the actual Liberty timing mapping.
synth -run fine: -noabc
opt_clean -purge
splitnets -format __v
yosys rename -wire -suffix _reg_p t:*DFF*_P*
yosys rename -wire -suffix _reg_n t:*DFF*_N*
autoname t:*DFF* %n
clockgate {*}$LIBS {*}$EXCLUDE_CELLS
if {[info exists LATCH_MAP_FILE] && [file exists $LATCH_MAP_FILE]} {
  techmap -map $LATCH_MAP_FILE
}
dfflibmap {*}$LIBS {*}$EXCLUDE_CELLS
opt -undriven -purge
log "NPC mapping target: $CLK_PERIOD_PS ps; explicit ABC map/upsize/dnsize delay"
abc -D $CLK_PERIOD_PS -constr $sdc_file {*}$LIBS {*}$EXCLUDE_CELLS \
    -script $strategy_script -showtmp
if {$DESIGN eq "riscv_core_reset_boundary"} {
  select -assert-count 1 t:riscv_multiplier*
  select -assert-count 1 t:riscv_divider*
}
tee -o $RESULT_DIR/unit_stat.txt stat {*}$LIBS
setattr -unset keep_hierarchy
flatten
opt_clean -purge
hilomap -singleton -hicell {*}$TIEHI_CELL_AND_PORT -locell {*}$TIELO_CELL_AND_PORT
setundef -zero
opt_clean -purge
autoname
write_verilog -noattr -noexpr -nohex -nodec $NETLIST_SYN_V.sim
splitnets -format __v -ports
opt_clean -purge
foreach library $LIB_FILES {read_liberty -lib $library}
tee -o $RESULT_DIR/synth_check.txt check -mapped
tee -o $RESULT_DIR/synth_stat.txt stat {*}$LIBS
write_verilog -noattr -noexpr -nohex -nodec $NETLIST_SYN_V
