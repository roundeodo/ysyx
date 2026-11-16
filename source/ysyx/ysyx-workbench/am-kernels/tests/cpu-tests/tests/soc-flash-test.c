#include <stdint.h>

#define FLASH_BASE 0x30000000u

static inline uint32_t flash_read32(uint32_t offset) {
  volatile uint32_t *addr =
      (volatile uint32_t *)(uintptr_t)(FLASH_BASE + offset);

  return *addr;
}

int main(void) {
  uint32_t value0 = flash_read32(0x0000);
  uint32_t value1 = flash_read32(0x0004);
  uint32_t value2 = flash_read32(0x0100);

  if (value0 != 0x12345678u) {
    return 1;
  }

  if (value1 != 0xdeadbeefu) {
    return 2;
  }

  if (value2 != 0xabcdef01u) {
    return 3;
  }

  return 0;
}