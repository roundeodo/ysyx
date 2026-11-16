#include "trap.h"

#include <stdint.h>

/*
 * 这段函数位于可写、可执行的SDRAM .text中。第一条指令最初返回1，测试运行时会
 * 把它改成返回2。先调用一次的目的，是让原指令所在cache line进入I-cache。
 */
__asm__(
    ".pushsection .text.smc_target_no_fence, \"ax\", @progbits\n"
    ".balign 4\n"
    ".global smc_target_no_fence\n"
    ".type smc_target_no_fence, @function\n"
    "smc_target_no_fence:\n"
    "  addi a0, zero, 1\n"
    "  ret\n"
    ".size smc_target_no_fence, .-smc_target_no_fence\n"
    ".popsection\n");

extern int smc_target_no_fence(void);

int main(void) {
  volatile uint32_t *const target_instruction =
      (volatile uint32_t *)(uintptr_t)smc_target_no_fence;

  const int result_before_patch = smc_target_no_fence();

  /* addi a0, zero, 2。store只更新SDRAM，不会主动更新I-cache中的旧副本。 */
  target_instruction[0] = 0x00200513u;

  /*
   * 这里只放编译器屏障，不执行fence.i。该测试用于复现当前实现的旧指令现象，
   * 不是ISA符合性测试：RISC-V允许在fence.i之前继续看到旧指令。
   */
  __asm__ volatile("" ::: "memory");
  const int result_without_fence_i = smc_target_no_fence();

  check(result_before_patch == 1);
  check(result_without_fence_i == 1);
  return 0;
}
