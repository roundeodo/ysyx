#include <am.h>

#define SERIAL_PORT 0x10000000

void __am_uart_init() {
}

void __am_uart_config(AM_UART_CONFIG_T *cfg) {
  cfg->present = true;
}

void __am_uart_tx(AM_UART_TX_T *uart) {
  putch(uart->data);
}

void __am_uart_rx(AM_UART_RX_T *uart) {
  uart->data = *(volatile char *)SERIAL_PORT;
}
