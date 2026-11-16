#include "trap.h"
#include <stdint.h>

#define PSRAM_TEST_START_ADDR ((uintptr_t)0x80000000u)
#define PSRAM_TEST_END_ADDR   ((uintptr_t)0x80400000u)

static uintptr_t align_up(uintptr_t addr, uintptr_t alignment) {
  return (addr + alignment - 1) & ~(alignment - 1);
}

int main(void) {
  const uintptr_t start = PSRAM_TEST_START_ADDR;
  const uintptr_t end   = PSRAM_TEST_END_ADDR;

  // Cover every PSRAM byte with 8-bit stores and loads.
  for (uintptr_t addr = start; addr < end; addr++) {
    *(volatile uint8_t *)addr = (uint8_t)(addr ^ 0x5a);
  }

  for (uintptr_t addr = start; addr < end; addr++) {
    uint8_t expected = (uint8_t)(addr ^ 0x5a);
    if (*(volatile uint8_t *)addr != expected) {
      halt(1);
    }
  }

  // Cover the complete PSRAM range with naturally aligned 16-bit accesses.
  for (uintptr_t addr = align_up(start, 2); addr + 2 <= end; addr += 2) {
    *(volatile uint16_t *)addr = (uint16_t)(addr ^ 0xa55a);
  }

  for (uintptr_t addr = align_up(start, 2); addr + 2 <= end; addr += 2) {
    uint16_t expected = (uint16_t)(addr ^ 0xa55a);
    if (*(volatile uint16_t *)addr != expected) {
      halt(2);
    }
  }

  // Cover the complete PSRAM range with naturally aligned 32-bit accesses.
  for (uintptr_t addr = align_up(start, 4); addr + 4 <= end; addr += 4) {
    *(volatile uint32_t *)addr = (uint32_t)(addr ^ 0xa5a55a5a);
  }

  for (uintptr_t addr = align_up(start, 4); addr + 4 <= end; addr += 4) {
    uint32_t expected = (uint32_t)(addr ^ 0xa5a55a5a);
    if (*(volatile uint32_t *)addr != expected) {
      halt(3);
    }
  }

  // RV32 implements each 64-bit C access as multiple 32-bit instructions.
  for (uintptr_t addr = align_up(start, 8); addr + 8 <= end; addr += 8) {
    uint64_t expected = ((uint64_t)(addr ^ 0x5aa55aa5u) << 32) | addr;
    *(volatile uint64_t *)addr = expected;
  }

  for (uintptr_t addr = align_up(start, 8); addr + 8 <= end; addr += 8) {
    uint64_t expected = ((uint64_t)(addr ^ 0x5aa55aa5u) << 32) | addr;
    if (*(volatile uint64_t *)addr != expected) {
      halt(4);
    }
  }

  return 0;
}
