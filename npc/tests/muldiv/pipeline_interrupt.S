/* Harness raises IRQ while a multiply occupies an internal pipeline register. */
.section .text
.globl _start
.option norvc
.option norelax
_start:
  li s0,0
  li s4,123
  li s5,45
  la t0,handler
  csrw mtvec,t0
  li t0,128
  csrw mie,t0
  csrsi mstatus,8
  .rept 12
  mul s1,s4,s5
  mul s2,s4,s5
  mul s3,s4,s5
  .endr
  li t0,5535
  bne s1,t0,fail
  bne s2,t0,fail
  bne s3,t0,fail
  li t0,1
  bne s0,t0,fail
  li a0,0
  ebreak
handler:
  csrr t1,mcause
  li t2,0x80000007
  bne t1,t2,fail
  addi s0,s0,1
  mret
fail:
  li a0,1
  ebreak
