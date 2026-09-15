/* RV32I 自检程序；a0=0 表示通过，非零为失败阶段。 */
.section .text
.globl _start
.option norvc
.option norelax
_start:
  li sp, 0x8001f000
  li s0, 0                      /* 定时器中断次数 */
  li s4, 0                      /* ecall 次数 */
  li s5, 0                      /* load access fault 次数 */
  li s1, 0x02004000
  li s2, 0x80010000
  la t0, trap_entry
  ori t0, t0, 1
  csrw mtvec, t0
  csrr t1, mtvec
  andi t1, t1, 3
  bnez t1, fail_1

  /* 制造 pending，分别检查全局和单源屏蔽。 */
  sw zero, 0(s1)
  sw zero, 4(s1)
  csrw mip, zero
  csrr t0, mip
  li t1, 128
  bne t0, t1, fail_1
  li t0, -1
  csrw mie, t0
  csrr t0, mie
  bne t0, t1, fail_1
  li t0, 20
1: addi t0, t0, -1
  bnez t0, 1b
  bnez s0, fail_1
  csrw mie, zero
  csrsi mstatus, 8
  li t0, 20
2: addi t0, t0, -1
  bnez t0, 2b
  bnez s0, fail_1
  csrci mstatus, 8
  li t0, 128
  csrw mie, t0
  li t0, 1
  csrw mscratch, t0
  csrsi mstatus, 8
.globl after_enable
after_enable:
  li t0, 1
  bne s0, t0, fail_1

  /* 周期定时和带访存的循环同时执行。 */
  li t0, 2
  csrw mscratch, t0
  call arm_timer
  li s3, 0
periodic_loop:
  addi s3, s3, 1
  /* 三个同组地址超过两路容量，强制发生脏替换及 AXI 写回。 */
  sw s3, 0(s2)
  sw s3, 256(s2)
  sw s3, 512(s2)
  lw t0, 0(s2)
  bne t0, s3, fail_2
  li t0, 10
  bltu s0, t0, periodic_loop
  li t0, -1
  sw t0, 0(s1)
  sw t0, 4(s1)

  fence.i                        /* 排空脏行并使 I-cache 失效 */

  /* 同步异常保留原语义，只给 ecall 的 mepc 加 4。 */
  li t0, 3
  csrw mscratch, t0
  ecall
  li t0, 1
  bne s4, t0, fail_3

  /* 测试环境延迟这次读并返回 SLVERR；定时器会在等待期间到期。 */
  li t0, 4
  csrw mscratch, t0
  li t0, 0x02000048
  lw t1, 0(t0)
  addi t1, t1, 20               /* 覆盖冷 I-cache 的取指延迟，再在错误读等待中到期 */
  li t0, -1
  sw t0, 0(s1)
  sw zero, 4(s1)
  sw t1, 0(s1)
  li t0, 0x8001e000
.globl faulting_load
faulting_load:
  lw t1, 0(t0)
  li t0, 1
  bne s5, t0, fail_4
  /* 访存异常处理程序保留 pending；mret 后必须立即响应定时器。 */
  li t0, 11
  bltu s0, t0, fail_4
  li t0, -1
  sw t0, 0(s1)
  sw t0, 4(s1)
  csrci mstatus, 8
  li a0, 0
  ebreak

/* low=-1, high=new_high, low=new_low，规避 RV32 分次写的中间比较值。 */
arm_timer:
  li t0, 0x02000048
  lw t1, 0(t0)
  addi t1, t1, 30
  li t0, -1
  sw t0, 0(s1)
  sw zero, 4(s1)
  sw t1, 0(s1)
  ret

.balign 4
trap_entry:
  addi sp, sp, -32
  sw t0, 0(sp)
  sw t1, 4(sp)
  sw t2, 8(sp)
  sw ra, 12(sp)
  csrr t0, mcause
  li t1, 0x80000007
  beq t0, t1, timer_handler
  li t1, 11
  beq t0, t1, ecall_handler
  li t1, 5
  beq t0, t1, load_fault_handler
  j fail_5

timer_handler:
  csrr t0, mtval
  bnez t0, fail_5
  csrr t0, mstatus
  li t1, 0x1880
  bne t0, t1, fail_5
  csrr t2, mscratch
  li t0, 1
  bne t2, t0, 3f
  csrr t0, mepc
  la t1, after_enable
  bne t0, t1, fail_1
3:
  addi s0, s0, 1
  li t0, 2
  beq t2, t0, periodic_rearm
  li t0, -1
  sw t0, 0(s1)
  sw t0, 4(s1)
  j trap_return
periodic_rearm:
  call arm_timer
  j trap_return

ecall_handler:
  addi s4, s4, 1
  csrr t0, mepc
  addi t0, t0, 4
  csrw mepc, t0
  j trap_return

load_fault_handler:
  csrr t0, mepc
  la t1, faulting_load
  bne t0, t1, fail_4
  csrr t1, mtval
  li t2, 0x8001e000
  bne t1, t2, fail_4
  csrr t1, mip
  andi t1, t1, 128
  beqz t1, fail_4
  addi s5, s5, 1
  addi t0, t0, 4
  csrw mepc, t0

trap_return:
  lw t0, 0(sp)
  lw t1, 4(sp)
  lw t2, 8(sp)
  lw ra, 12(sp)
  addi sp, sp, 32
  mret

fail_1: li a0, 1; ebreak
fail_2: li a0, 2; ebreak
fail_3: li a0, 3; ebreak
fail_4: li a0, 4; ebreak
fail_5: li a0, 5; ebreak
