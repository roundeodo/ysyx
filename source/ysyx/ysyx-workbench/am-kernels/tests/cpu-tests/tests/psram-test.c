#include "trap.h"

#include <stdint.h>
#include <stdio.h>

#define PSRAM_TEST_BASE_ADDR 0x80000000u
#define PSRAM_TEST_BYTE_SIZE 0x00001000u

static void test_byte_access(void) {
  volatile uint8_t *const psram =
      (volatile uint8_t *)(uintptr_t)PSRAM_TEST_BASE_ADDR;

  printf("PSRAM: testing 8-bit accesses...\n");

  for (uint32_t byte_offset = 0; byte_offset < PSRAM_TEST_BYTE_SIZE;
       byte_offset++) {
    psram[byte_offset] = (uint8_t)(byte_offset ^ 0x5au);
  }

  for (uint32_t byte_offset = 0; byte_offset < PSRAM_TEST_BYTE_SIZE;
       byte_offset++) {
    const uint8_t expected = (uint8_t)(byte_offset ^ 0x5au);
    const uint8_t actual   = psram[byte_offset];

    if (actual != expected) {
      printf("PSRAM 8-bit mismatch: addr=0x%x expected=0x%x actual=0x%x\n",
             PSRAM_TEST_BASE_ADDR + byte_offset, expected, actual);
      halt(1);
    }
  }
}

static void test_halfword_access(void) {
  volatile uint16_t *const psram =
      (volatile uint16_t *)(uintptr_t)PSRAM_TEST_BASE_ADDR;
  const uint32_t halfword_count = PSRAM_TEST_BYTE_SIZE / sizeof(uint16_t);

  printf("PSRAM: testing 16-bit accesses...\n");

  for (uint32_t halfword_index = 0; halfword_index < halfword_count;
       halfword_index++) {
    const uint32_t byte_offset = halfword_index * sizeof(uint16_t);
    psram[halfword_index] = (uint16_t)(byte_offset ^ 0xa55au);
  }

  for (uint32_t halfword_index = 0; halfword_index < halfword_count;
       halfword_index++) {
    const uint32_t byte_offset = halfword_index * sizeof(uint16_t);
    const uint16_t expected    = (uint16_t)(byte_offset ^ 0xa55au);
    const uint16_t actual      = psram[halfword_index];

    if (actual != expected) {
      printf("PSRAM 16-bit mismatch: addr=0x%x expected=0x%x actual=0x%x\n",
             PSRAM_TEST_BASE_ADDR + byte_offset, expected, actual);
      halt(2);
    }
  }
}

static void test_word_access(void) {
  volatile uint32_t *const psram =
      (volatile uint32_t *)(uintptr_t)PSRAM_TEST_BASE_ADDR;
  const uint32_t word_count = PSRAM_TEST_BYTE_SIZE / sizeof(uint32_t);

  printf("PSRAM: testing 32-bit accesses...\n");

  for (uint32_t word_index = 0; word_index < word_count; word_index++) {
    const uint32_t byte_offset = word_index * sizeof(uint32_t);
    psram[word_index] = byte_offset ^ 0xa5a55a5au;
  }

  for (uint32_t word_index = 0; word_index < word_count; word_index++) {
    const uint32_t byte_offset = word_index * sizeof(uint32_t);
    const uint32_t expected    = byte_offset ^ 0xa5a55a5au;
    const uint32_t actual      = psram[word_index];

    if (actual != expected) {
      printf("PSRAM 32-bit mismatch: addr=0x%x expected=0x%x actual=0x%x\n",
             PSRAM_TEST_BASE_ADDR + byte_offset, expected, actual);
      halt(3);
    }
  }
}

static void test_doubleword_access(void) {
  volatile uint64_t *const psram =
      (volatile uint64_t *)(uintptr_t)PSRAM_TEST_BASE_ADDR;
  const uint32_t doubleword_count = PSRAM_TEST_BYTE_SIZE / sizeof(uint64_t);

  printf("PSRAM: testing 64-bit accesses as RV32 word pairs...\n");

  for (uint32_t doubleword_index = 0;
       doubleword_index < doubleword_count; doubleword_index++) {
    const uint32_t byte_offset = doubleword_index * sizeof(uint64_t);
    const uint64_t pattern =
        ((uint64_t)(byte_offset ^ 0x89abcdefu) << 32) |
        (uint64_t)(byte_offset ^ 0x01234567u);

    psram[doubleword_index] = pattern;
  }

  for (uint32_t doubleword_index = 0;
       doubleword_index < doubleword_count; doubleword_index++) {
    const uint32_t byte_offset = doubleword_index * sizeof(uint64_t);
    const uint64_t expected =
        ((uint64_t)(byte_offset ^ 0x89abcdefu) << 32) |
        (uint64_t)(byte_offset ^ 0x01234567u);
    const uint64_t actual = psram[doubleword_index];

    if (actual != expected) {
      printf("PSRAM 64-bit mismatch: addr=0x%x\n",
             PSRAM_TEST_BASE_ADDR + byte_offset);
      printf("  expected: high=0x%x low=0x%x\n",
             (uint32_t)(expected >> 32), (uint32_t)expected);
      printf("  actual:   high=0x%x low=0x%x\n",
             (uint32_t)(actual >> 32), (uint32_t)actual);
      halt(4);
    }
  }
}

int main(void) {
  printf("PSRAM test range: [0x%x, 0x%x)\n", PSRAM_TEST_BASE_ADDR,
         PSRAM_TEST_BASE_ADDR + PSRAM_TEST_BYTE_SIZE);

  test_byte_access();
  test_halfword_access();
  test_word_access();
  test_doubleword_access();

  printf("PSRAM test passed.\n");
  return 0;
}
