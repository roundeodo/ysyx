// Three native timer samples around a synchronous exception. No CSR performance
// reads. The observer must exclude ECALL/EBREAK and include handler retirement.
.section .text
.globl _start
_start:
  la t3, handler
  csrw mtvec, t3
  lui t0, 0x2000
first_sample:
  lw t1, 72(t0)
  lw t2, 76(t0)
  addi s0, zero, 1
  addi s1, zero, 2
  addi s2, zero, 3
  ecall
second_sample:
  lw t1, 72(t0)
  lw t2, 76(t0)
  addi s3, zero, 4
third_sample:
  lw t1, 72(t0)
  lw t2, 76(t0)
  li a0, 0
  ebreak
handler:
  csrr t3, mepc
  addi t3, t3, 4
  csrw mepc, t3
  mret
