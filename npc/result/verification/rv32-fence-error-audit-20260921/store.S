.option norvc
.section .text
.globl _start
_start:
  li s0,0
  lui s1,0x80000
  addi s1,s1,0x80
  lui s2,0x10002
  lui s3,0x0f000
  j site
.org 0x40
patch:
  li t0,0x89a023
  sw t0,0(s1)
  li s0,1
  j fence
.org 0x7c
fence:
  fence.i
site:
  j target
  j good
.org 0x100
target:
  bnez s0,bad
  j patch
.org 0x120
bad:
  sw s0,0(s2)
  j halt
.org 0x180
good:
  sw s0,4(s2)
  j halt
.org 0x1c0
halt:
  j halt
