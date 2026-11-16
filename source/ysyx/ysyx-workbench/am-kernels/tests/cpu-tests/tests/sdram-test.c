#include "trap.h"

#include <stdint.h>
#include <stdio.h>

#define SDRAM_TEST_BASE_ADDR 0xa0000000u
#define SDRAM_TEST_BYTE_SIZE 0x00001000u

static uint32_t select_word_test_pattern(uint32_t word_index) {
  const uint32_t byte_offset = word_index * sizeof(uint32_t);
  return (SDRAM_TEST_BASE_ADDR + byte_offset) ^ 0xa5a55a5au;
}

static void test_complete_word_range(void) {
  volatile uint32_t *const sdram_words =
      (volatile uint32_t *)(uintptr_t)SDRAM_TEST_BASE_ADDR;
  const uint32_t word_count = SDRAM_TEST_BYTE_SIZE / sizeof(uint32_t);

  printf("SDRAM: testing 4 KiB with 32-bit accesses...\n");

  for (uint32_t word_index = 0; word_index < word_count; word_index++) {
    sdram_words[word_index] = select_word_test_pattern(word_index);
  }

  for (uint32_t word_index = 0; word_index < word_count; word_index++) {
    const uint32_t expected = select_word_test_pattern(word_index);
    const uint32_t actual   = sdram_words[word_index];

    if (actual != expected) {
      const uint32_t failed_addr =
          SDRAM_TEST_BASE_ADDR + word_index * sizeof(uint32_t);
      printf("SDRAM word mismatch: addr=0x%x expected=0x%x actual=0x%x\n",
             failed_addr, expected, actual);
      halt(1);
    }
  }
}

static void test_byte_write_strobes(void) {
  const uintptr_t test_addr = SDRAM_TEST_BASE_ADDR + 0x100u;
  volatile uint32_t *const test_word =
      (volatile uint32_t *)(uintptr_t)test_addr;
  volatile uint8_t *const test_bytes =
      (volatile uint8_t *)(uintptr_t)test_addr;

  printf("SDRAM: testing four byte write strobes...\n");

  *test_word     = 0u;
  test_bytes[0] = 0x11u;
  test_bytes[1] = 0x22u;
  test_bytes[2] = 0x33u;
  test_bytes[3] = 0x44u;

  if (*test_word != 0x44332211u) {
    printf("SDRAM byte-strobe mismatch: expected=0x44332211 actual=0x%x\n",
           *test_word);
    halt(2);
  }
}

static void test_halfword_write_strobes(void) {
  const uintptr_t test_addr = SDRAM_TEST_BASE_ADDR + 0x200u;
  volatile uint32_t *const test_word =
      (volatile uint32_t *)(uintptr_t)test_addr;
  volatile uint16_t *const test_halfwords =
      (volatile uint16_t *)(uintptr_t)test_addr;

  printf("SDRAM: testing two halfword write strobes...\n");

  *test_word         = 0u;
  test_halfwords[0] = 0x55aau;
  test_halfwords[1] = 0xa55au;

  if (*test_word != 0xa55a55aau) {
    printf("SDRAM halfword-strobe mismatch: expected=0xa55a55aa actual=0x%x\n",
           *test_word);
    halt(3);
  }
}

int main(void) {
  printf("SDRAM test range: [0x%x, 0x%x)\n", SDRAM_TEST_BASE_ADDR,
         SDRAM_TEST_BASE_ADDR + SDRAM_TEST_BYTE_SIZE);

  test_complete_word_range();
  test_byte_write_strobes();
  test_halfword_write_strobes();

  printf("SDRAM test passed.\n");
  return 0;
}
