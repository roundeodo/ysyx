#include <am.h>
#include <stdint.h>
#include <stdio.h>
#include "spi.h"

int main(void) {
  spi_init();

  const uint8_t input = 0xd2u;
  const uint8_t expected = 0x4bu;
  const uint8_t actual = spi_bitrev(input);

  printf("input    = 0x%02x\n", input);
  printf("expected = 0x%02x\n", expected);
  printf("actual   = 0x%02x\n", actual);

  halt(actual == expected ? 0 : 1);
}