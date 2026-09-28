.section .text.start
.globl _start
_start:
li sp,0x800f0000
call main
ebreak
