#include <stdint.h>

#define UART_BASE_ADDR 0x10000000u
#define UART_TX_OFFSET 0x0u

void _start(void) {
  volatile uint8_t *const uart_tx =
      (volatile uint8_t *)(UART_BASE_ADDR + UART_TX_OFFSET);

  *uart_tx = 'A';
  // *uart_tx = '\n';

  while (1) {
  }
}
