.section .text.start
.globl _start, workload_begin, workload_end
_start:
  la sp, _stack_top
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
