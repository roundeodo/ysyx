set SDC_FILE   [lindex $argv 0]
set NETLIST_V  [lindex $argv 1]
set DESIGN     [lindex $argv 2]
set PDK        [lindex $argv 3]
set RESULT_DIR [file dirname $NETLIST_V]

source "[file dirname [info script]]/common.tcl"

set_design_workspace $RESULT_DIR
read_netlist $NETLIST_V
read_liberty [concat $LIB_FILES]
link_design $DESIGN
read_sdc  $SDC_FILE
report_timing -max_path 5

# Power graph construction is substantially more expensive than timing on the
# complete NPC. Keep the reproducible timing baseline fast, and enable the
# vectorless power estimate explicitly when it is the measurement objective.
set RUN_POWER_ANALYSIS 0
if {[info exists env(RUN_POWER_ANALYSIS)]} {
  set RUN_POWER_ANALYSIS $::env(RUN_POWER_ANALYSIS)
}
if {$RUN_POWER_ANALYSIS} {
  report_power -toggle 0.1
}
