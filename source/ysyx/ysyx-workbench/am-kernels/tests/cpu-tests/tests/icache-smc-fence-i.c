#include "trap.h"

#include <stdint.h>

/* 与无fence.i测试使用独立符号，避免链接或调试时混淆两个实验对象。 */
__asm__(
    ".pushsection .text.smc_target_fence_i, \"ax\", @progbits\n"
    ".balign 4\n"
    ".global smc_target_fence_i\n"
    ".type smc_target_fence_i, @function\n"
    "smc_target_fence_i:\n"
    "  addi a0, zero, 1\n"
    "  ret\n"
    ".size smc_target_fence_i, .-smc_target_fence_i\n"
    ".popsection\n");

extern int smc_target_fence_i(void);

int main(void) {
  volatile uint32_t *const target_instruction =
      (volatile uint32_t *)(uintptr_t)smc_target_fence_i;

  const int result_before_patch = smc_target_fence_i();

  /* addi a0, zero, 2。 */
  target_instruction[0] = 0x00200513u;

  /*
   * memory clobber约束编译器不得把访存移过该点；fence.i约束处理器后续取指
   * 必须看到此前已经完成的指令存储。当前RTL通过整片I-cache失效实现该语义。
   */
  __asm__ volatile("fence.i" ::: "memory");
  const int result_after_fence_i = smc_target_fence_i();

  check(result_before_patch == 1);
  check(result_after_fence_i == 2);
  return 0;
}
