.section .text.start
.globl _start
.option norvc
.option norelax
_start:
  li sp, 0x8001f000
  call main
  call halt
