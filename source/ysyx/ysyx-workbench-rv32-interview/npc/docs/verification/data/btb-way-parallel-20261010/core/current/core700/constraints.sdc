# 原始 rst_ni 是异步输入，不为它虚构相对 core_clock 的到达时间。
# 它只连接 reset controller 的三个异步端口；同步释放 Q 到核内 RN 保留 STA。
set CLK_FREQ_MHZ $::env(CLK_FREQ_MHZ)
set clock_period_ns [expr 1000.0 / $CLK_FREQ_MHZ]
set io_delay_ns [expr 0.2 * $clock_period_ns]
create_clock -name core_clock -period $clock_period_ns [get_ports clk_i]
set_input_transition 0.1 [all_inputs]
set_output_delay $io_delay_ns -clock core_clock [all_outputs]

# iSTA 的 collection 是不透明句柄。读取当前展平标量网表，明确约束每个数据输入，
# 避免 all_inputs 将原始异步复位误当作同步数据；不使用全局复位 false-path。
set netlist_file [open $::env(NPC_STA_NETLIST_FILE) r]
set netlist_text [read $netlist_file]
close $netlist_file
set data_input_count 0
foreach line [split $netlist_text "\n"] {
  if {[regexp {^\s*input\s+([A-Za-z_][A-Za-z0-9_]*)\s*;} $line match port_name]} {
    if {$port_name ne "rst_ni" && $port_name ne "clk_i"} {
      set_input_delay $io_delay_ns -clock core_clock [get_ports $port_name]
      incr data_input_count
    }
  }
}
if {$data_input_count == 0} {error "No scalar data input ports found in STA netlist"}
puts "Reset-boundary STA: constrained $data_input_count data inputs; raw rst_ni is asynchronous"
