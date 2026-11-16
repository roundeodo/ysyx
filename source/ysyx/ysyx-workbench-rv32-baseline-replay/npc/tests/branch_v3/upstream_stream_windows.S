/* One binary, two passive ROI starts. Both modes execute exactly the same code. */
.section .text.start
.globl _start, workload_cold_begin, workload_begin, workload_end
_start:
  la sp, _stack_top
workload_cold_begin:
  nop
  call warm_prefix
workload_begin:
  nop
  call run_workload
workload_end:
  nop
  call validate_workload
  li t0, 0x10002000
  sw a0, 0(t0)
  ebreak
1: j 1b
