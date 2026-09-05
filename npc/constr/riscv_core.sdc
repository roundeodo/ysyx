set CLK_PORT_NAME clk_i
if {[info exists env(CLK_PORT_NAME)]} {
  set CLK_PORT_NAME $::env(CLK_PORT_NAME)
}

set CLK_FREQ_MHZ 300
if {[info exists env(CLK_FREQ_MHZ)]} {
  set CLK_FREQ_MHZ $::env(CLK_FREQ_MHZ)
}

set clock_period_ns [expr 1000.0 / $CLK_FREQ_MHZ]
set io_delay_ns     [expr 0.2 * $clock_period_ns]
set core_clock_port [get_ports $CLK_PORT_NAME]

create_clock -name core_clock -period $clock_period_ns $core_clock_port

set input_ports [all_inputs]
set_input_delay $io_delay_ns -clock core_clock $input_ports
set_input_delay 0.0 -clock core_clock $core_clock_port
set_input_transition 0.1 $input_ports

set output_ports [all_outputs]
set_output_delay $io_delay_ns -clock core_clock $output_ports

set_false_path -from [get_ports rst_ni]
