.option norvc
.section .text
.globl _start
_start:
  lla s1,first_data
  lui s2,0x10002
  lla t0,handler
  csrw mtvec,t0
  lui s0,0xdeadc
  addi s0,s0,-273
  sw s0,0(s1)
  li t5,SET_STRIDE
  add t5,s1,t5
  lw t1,0(t5)
  MISS_INSTRUCTION
  j bad
.org 0x100
handler:
  lw t3,0(s1)
  bne t3,s0,bad
  li t5,DOUBLE_SET_STRIDE
  add t5,s1,t5
  lw t1,0(t5)
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
first_data:
.word 0
.org SECOND_DATA_OFFSET
.word 0
.org THIRD_DATA_OFFSET
.word 0
