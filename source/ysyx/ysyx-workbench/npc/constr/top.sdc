set CLK_PORT_NAME clk
if {[info exists env(CLK_PORT_NAME)]} {
  set CLK_PORT_NAME $::env(CLK_PORT_NAME)
} else {
  puts "Warning: Environment CLK_PORT_NAME is not defined. Use $CLK_PORT_NAME by default."
}

set CLK_FREQ_MHZ 500
if {[info exists env(CLK_FREQ_MHZ)]} {
  set CLK_FREQ_MHZ $::env(CLK_FREQ_MHZ)
} else {
  puts "Warning: Environment CLK_FREQ_MHZ is not defined. Use $CLK_FREQ_MHZ MHz by default."
}

set clk_io_pct 0.2
set clk_port [get_ports $CLK_PORT_NAME]
create_clock -name core_clock -period [expr 1000.0 / $CLK_FREQ_MHZ] $clk_port

set_input_delay [expr 0.2 * (1000.0 / $CLK_FREQ_MHZ)] -clock core_clock [get_ports {in rst}]
set_input_transition 0.1 [get_ports {in rst}]

set_output_delay [expr 0.2 *(1000.0 / $CLK_FREQ_MHZ)] -clock core_clock [get_ports {out}]
set_load 0.01 [get_ports out]

set_input_transition 0.1 $clk_port

