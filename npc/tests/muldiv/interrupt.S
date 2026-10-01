/* Harness asserts timer IRQ eight cycles into the first division. */
.section .text
.globl _start
.option norvc
.option norelax
_start:
  li s0,0
  li t0,0x76543210
  li t1,17
  la t2,handler
  csrw mtvec,t2
  li t2,128
  csrw mie,t2
  csrsi mstatus,8
  /* RAW keeps resume_site unissued until division completes, including ROB mode.
     The IRQ is already pending then, so the exact expected mepc stays resume_site. */
  li s2,0x06f5e4d3
  divu s1,t0,t1
resume_site:
  bne s1,s2,fail_1
  li t2,1
  bne s0,t2,fail_2
  mul t3,s1,t1
  li t2,0x76543203
  bne t3,t2,fail_3
  li a0,0
  ebreak
handler:
  csrr t2,mcause
  li t3,0x80000007
  bne t2,t3,fail_4
  csrr t2,mepc
  la t3,resume_site
  bne t2,t3,fail_5
  addi s0,s0,1
  mret
fail:
  li a0,1
  ebreak
fail_1: li a0,2; ebreak
fail_2: li a0,3; ebreak
fail_3: li a0,4; ebreak
fail_4: li a0,5; ebreak
fail_5: li a0,6; ebreak
