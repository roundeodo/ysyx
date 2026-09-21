.option norvc
.section .text
.globl _start
_start:
  lui s1,0x80000
  addi s1,s1,0x400
  lui s2,0x10002
  lui t0,0x80000
  addi t0,t0,0x100
  csrw mtvec,t0
  li s0,0xdeadbeef
  sw s0,0(s1)
  lw t1,128(s1)
  MISS_INSTRUCTION
  j bad
.org 0x100
handler:
  lw t3,0(s1)
  bne t3,s0,bad
  lw t1,256(s1)
  lw t3,0(s1)
  bne t3,s0,bad
  sw t3,4(s2)
  j halt
.org 0x180
bad:
  sw s0,0(s2)
.org 0x1c0
halt:
  j halt
.org 0x400
.word 0
.org 0x480
.word 0
.org 0x500
.word 0
