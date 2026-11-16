#include "trap.h"

#include <stdint.h>

static volatile uintptr_t observed_mcause;
static volatile uintptr_t observed_mtval;

// 该入口只验证最小M-mode异常闭环。它不调用C函数，因此无需构造第二套Context保存逻辑。
__attribute__((naked, aligned(4))) static void trap_entry(void) {
  asm volatile(
      "csrr t0, mcause\n"
      "la   t1, observed_mcause\n"
#if __riscv_xlen == 64
      "sd   t0, 0(t1)\n"
#else
      "sw   t0, 0(t1)\n"
#endif
      "csrr t0, mtval\n"
      "la   t1, observed_mtval\n"
#if __riscv_xlen == 64
      "sd   t0, 0(t1)\n"
#else
      "sw   t0, 0(t1)\n"
#endif
      // ECALL返回地址是触发异常的指令地址，软件必须显式跳过该指令。
      "csrr t0, mepc\n"
      "addi t0, t0, 4\n"
      "csrw mepc, t0\n"
      "mret\n");
}

int main(void) {
  uintptr_t mstatus_after_mret;

  asm volatile("csrw mtvec, %0" : : "r"(trap_entry));
  asm volatile("ecall");
  asm volatile("csrr %0, mstatus" : "=r"(mstatus_after_mret));

  check(observed_mcause == 11);
  check(observed_mtval == 0);
  check(((mstatus_after_mret >> 3) & 1) == 0);
  check(((mstatus_after_mret >> 7) & 1) == 1);
  return 0;
}
