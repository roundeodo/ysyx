.section .text.start
.globl _start, workload_begin, workload_end
_start:
  la sp, _stack_top
workload_begin:
  nop
  call run
workload_end:
  nop
  li t0, 0x10002000
  sw a0, 0(t0)
  ebreak
1: j 1b
