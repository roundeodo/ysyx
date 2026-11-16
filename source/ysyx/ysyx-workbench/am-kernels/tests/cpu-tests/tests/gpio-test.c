#include <gpio.h>
#include <stdint.h>

#define SWITCH_PASSWORD            0xa55au
#define SEVEN_SEGMENT_TEST_VALUE   0x12345678u
#define RUNNING_LIGHT_DELAY_COUNT  20000u

static void delay_running_light(void) {
  for (volatile uint32_t count = 0;
       count < RUNNING_LIGHT_DELAY_COUNT;
       count++) {
    asm volatile("nop");
  }
}

int main(void) {
  uint16_t running_led_pattern = 1u;

  gpio_write_seven_segment_digits(SEVEN_SEGMENT_TEST_VALUE);

  /*
   * 在等待拨码开关密码期间持续显示流水灯。
   * 当SW[15:0]等于0xa55a时退出循环。
   */
  while (gpio_read_switches() != SWITCH_PASSWORD) {
    gpio_write_leds(running_led_pattern);
    delay_running_light();

    if (running_led_pattern == 0x8000u) {
      running_led_pattern = 1u;
    } else {
      running_led_pattern <<= 1;
    }
  }

  // 密码正确后点亮全部LED，随后以good trap结束。
  gpio_write_leds(0xffffu);
  delay_running_light();

  return 0;
}