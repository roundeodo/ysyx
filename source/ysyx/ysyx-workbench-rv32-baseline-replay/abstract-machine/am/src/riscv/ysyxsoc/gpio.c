#include <gpio.h>
#include <stdint.h>

#define GPIO_BASE_ADDRESS 0x10002000u
#define GPIO_LED_OFFSET 0x00u
#define GPIO_SWITCH_OFFSET 0x04u
#define GPIO_SEGMENT_OFFSET 0x08u

static inline void gpio_write_register(uint32_t offset, uint32_t value) {
    *(volatile uint32_t *)(uintptr_t)(GPIO_BASE_ADDRESS + offset) = value;
}

static inline uint32_t gpio_read_register(uint32_t offset) {
  return *(volatile uint32_t *)(uintptr_t)(GPIO_BASE_ADDRESS + offset);
}

void gpio_write_leds(uint16_t led_values) {
  gpio_write_register(GPIO_LED_OFFSET, (uint32_t)led_values);
}

uint16_t gpio_read_switches(void) {
  return (uint16_t)gpio_read_register(GPIO_SWITCH_OFFSET);
}

void gpio_write_seven_segment_digits(uint32_t digit_values) {
  gpio_write_register(GPIO_SEGMENT_OFFSET, digit_values);
}