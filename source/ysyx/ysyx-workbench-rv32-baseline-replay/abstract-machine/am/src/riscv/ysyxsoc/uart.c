#include <am.h>
#include <stdint.h>
#include <uart.h>

#define UART_BASE 0x10000000u

#define UART_THR 0u
#define UART_RBR 0u
#define UART_DLL 0u
#define UART_IER 1u
#define UART_DLM 1u
#define UART_FCR 2u
#define UART_LCR 3u
#define UART_LSR 5u

#define UART_LCR_DLAB (1u << 7)
#define UART_LSR_DATA_READY (1u << 0)
#define UART_LSR_THRE (1u << 5)

static inline void uart_write(uint32_t offset, uint8_t data) {
  *(volatile uint8_t *)(UART_BASE + offset) = data;
}

static inline uint8_t uart_read(uint32_t offset) {
  return *(volatile uint8_t *)(UART_BASE + offset);
}

void uart_init(void) {
  uart_write(UART_LCR, UART_LCR_DLAB);
  uart_write(UART_DLL, 1);
  uart_write(UART_DLM, 0);

  uart_write(UART_LCR, 0x03);
  uart_write(UART_FCR, 0x07);
  uart_write(UART_IER, 0x00);
}

void uart_putc(char ch) {
  while ((uart_read(UART_LSR) & UART_LSR_THRE) == 0) {
  }

  uart_write(UART_THR, (uint8_t)ch);
}

void __am_uart_init(void) {
  uart_init();
}

void __am_uart_config(AM_UART_CONFIG_T *config) {
  config->present = true;
}

void __am_uart_tx(AM_UART_TX_T *tx) {
  uart_putc(tx->data);
}

void __am_uart_rx(AM_UART_RX_T *rx) {
  if ((uart_read(UART_LSR) & UART_LSR_DATA_READY) != 0) {
    rx->data = (char)uart_read(UART_RBR);
  } else {
    rx->data = (char)0xff;
  }
}
