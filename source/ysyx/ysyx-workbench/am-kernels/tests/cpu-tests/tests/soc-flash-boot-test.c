#include <stdint.h>
#include <flash.h>

#define FLASH_PAYLOAD_OFFSET 0x00000000u
#define SRAM_PROGRAM_ENTRY   0x0f000000u


#define PROGRAM_BYTE_COUNT 16u

typedef void (*program_entry_t)(void);

int main(void) {
  volatile uint32_t *const sram_program =
      (volatile uint32_t *)(uintptr_t)SRAM_PROGRAM_ENTRY;

  for (uint32_t offset = 0; offset < PROGRAM_BYTE_COUNT;
       offset += sizeof(uint32_t)) {
    sram_program[offset / sizeof(uint32_t)] =
        flash_read(FLASH_PAYLOAD_OFFSET + offset);
  }

  __asm__ volatile(".word 0x0000100f" ::: "memory");

  program_entry_t program_entry =
      (program_entry_t)(uintptr_t)SRAM_PROGRAM_ENTRY;

  program_entry();

  return 1;
}
