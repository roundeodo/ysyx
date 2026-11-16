.option norvc
.option norelax
.section .text
.globl _start
_start:
  li s0, 256
  li t0, -1
  li t1, 7
  li t2, 11
  li t3, 13
  li t4, 17
#if BENCH_KIND == 5 || BENCH_KIND == 7
  la s8, data_value
#endif
loop:
#if BENCH_KIND == 0
  divu s1, t0, t1
  mul s2, t2, t3
  mul s3, t2, t4
  mul s4, t3, t4
  add s5, t2, t3
  add s6, t3, t4
  xor s7, t2, t4
#elif BENCH_KIND == 1
  mul s1, t2, t3
  mul s2, t2, t3
  mul s3, t2, t4
  mul s4, t3, t4
  mul s5, t2, t3
  mul s6, t2, t4
  mul s7, t3, t4
#elif BENCH_KIND == 2
  add s1, t2, t3
  add s2, t2, t3
  add s3, t2, t4
  add s4, t3, t4
  add s5, t2, t3
  add s6, t2, t4
  add s7, t3, t4
#elif BENCH_KIND == 3
  addi t2, t2, 1
  addi t2, t2, 1
  addi t2, t2, 1
  addi t2, t2, 1
  addi t2, t2, 1
  addi t2, t2, 1
  addi t2, t2, 1
#elif BENCH_KIND == 4
  addi s1, t2, 1
  addi s2, s1, 1
  addi s3, s2, 1
  addi s4, s3, 1
  addi s5, s4, 1
  addi s6, s5, 1
  addi t2, s6, 1
#elif BENCH_KIND == 5
  divu s1, t0, t1
  ld s2, 0(s8)
  addi s3, s2, 1
  mul s4, t2, t3
  add s5, t2, t3
  add s6, t3, t4
  xor s7, t2, t4
#elif BENCH_KIND == 6
  divu s1, t0, t1
  addi s1, t2, 1
  mul s1, t2, t3
  addi s2, s1, 1
  addi s1, s1, 1
  addi s1, s1, 1
  addi s3, s1, 1
#elif BENCH_KIND == 7
  ld s1, 0(s8)
  addi s1, s1, 1
  sd s1, 0(s8)
  ld s2, 0(s8)
  addi s2, s2, 1
  sd s2, 0(s8)
  addi s3, s2, 1
#else
#error Unknown BENCH_KIND
#endif
  addi s0, s0, -1
  bnez s0, loop
#if BENCH_KIND == 0
  li t5, 0x2492492492492492
  bne s1, t5, fail
  li t5, 143
  bne s2, t5, fail
  li t5, 187
  bne s3, t5, fail
  li t5, 221
  bne s4, t5, fail
  li t5, 24
  bne s5, t5, fail
  li t5, 30
  bne s6, t5, fail
  li t5, 26
  bne s7, t5, fail
#elif BENCH_KIND == 1
  li t5, 143
  bne s1, t5, fail
  bne s2, t5, fail
  bne s5, t5, fail
  li t5, 187
  bne s3, t5, fail
  bne s6, t5, fail
  li t5, 221
  bne s4, t5, fail
  bne s7, t5, fail
#elif BENCH_KIND == 2
  li t5, 24
  bne s1, t5, fail
  bne s2, t5, fail
  bne s5, t5, fail
  li t5, 28
  bne s3, t5, fail
  bne s6, t5, fail
  li t5, 30
  bne s4, t5, fail
  bne s7, t5, fail
#elif BENCH_KIND == 5
  li t5, 0x2492492492492492
  bne s1, t5, fail
  li t5, 41
  bne s2, t5, fail
  li t5, 42
  bne s3, t5, fail
  li t5, 143
  bne s4, t5, fail
#elif BENCH_KIND == 6
  li t5, 145
  bne s1, t5, fail
  li t5, 144
  bne s2, t5, fail
  li t5, 146
  bne s3, t5, fail
#elif BENCH_KIND == 7
  li t5, 553
  bne s2, t5, fail
  li t5, 554
  bne s3, t5, fail
#else
  li t5, 1803
  bne t2, t5, fail
#endif
  li a0, 0
  ebreak
fail:
  li a0, 1
  ebreak

#if BENCH_KIND == 5 || BENCH_KIND == 7
.section .data
.balign 8
data_value:
  .dword 41
#endif
