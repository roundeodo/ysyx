#include "trap.h"

#include <stdint.h>

#define SDRAM_EXEC_BASE_ADDR 0xa0000000u

typedef uint32_t (*sdram_test_function_t)(void);

int main(void) {
  volatile uint32_t *const sdram_instructions =
      (volatile uint32_t *)(uintptr_t)SDRAM_EXEC_BASE_ADDR;

  // 写入addi a0, x0, 42和返回指令，作为之后从SDRAM执行的最小函数。
  sdram_instructions[0] = 0x02a00513u;
  sdram_instructions[1] = 0x00008067u;

  // 前面的store修改了未来要取指的地址；跳转前用fence.i清除旧I-cache状态。
  __asm__ volatile("fence.i" ::: "memory");

  const sdram_test_function_t sdram_test_function =
      (sdram_test_function_t)(uintptr_t)SDRAM_EXEC_BASE_ADDR;
  check(sdram_test_function() == 42u);
  return 0;
}
