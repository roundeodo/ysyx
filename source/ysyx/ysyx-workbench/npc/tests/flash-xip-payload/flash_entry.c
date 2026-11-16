#include <stdint.h>

#define UART_TX_ADDR 0x10000000u
#define FLASH_RETURN_VALUE 0x58495031u

__attribute__((section(".text.flash_entry"), noinline))
uint32_t flash_entry(void){
    *(volatile uint8_t *)(uintptr_t)UART_TX_ADDR = (uint8_t)'X';
    *(volatile uint8_t *)(uintptr_t)UART_TX_ADDR = (uint8_t)'\n';
    return FLASH_RETURN_VALUE;
}