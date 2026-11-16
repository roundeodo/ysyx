#include <stdint.h>

#define UART_TX_ADDR 0x10000000u

void _start(void) {
  *(volatile uint8_t *)(uintptr_t)UART_TX_ADDR = (uint8_t)'A';

  while (1) {
  }
}
