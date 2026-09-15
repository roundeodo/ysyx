#ifndef AM_RISCV_YSYXSOC_GPIO_H
#define AM_RISCV_YSYXSOC_GPIO_H

#include <stdint.h>

void gpio_write_leds(uint16_t led_values);
uint16_t gpio_read_switches(void);
void gpio_write_seven_segment_digits(uint32_t digit_values);

#endif