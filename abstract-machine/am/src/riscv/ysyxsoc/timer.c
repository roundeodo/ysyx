#include <am.h>
#include <stdint.h>

#define CLINT_MTIME_LOW_ADDR  0x02000048u
#define CLINT_MTIME_HIGH_ADDR 0x0200004cu

static uint64_t boot_time_us;

static uint64_t read_mtime_us(void) {
  uint32_t low = *(volatile uint32_t *)CLINT_MTIME_LOW_ADDR;
  uint32_t high = *(volatile uint32_t *)CLINT_MTIME_HIGH_ADDR;
  return ((uint64_t)high << 32) | low;
}

void __am_timer_init(void) {
  boot_time_us = read_mtime_us();
}

void __am_timer_uptime(AM_TIMER_UPTIME_T *uptime) {
  uptime->us = read_mtime_us() - boot_time_us;
}

void __am_timer_rtc(AM_TIMER_RTC_T *rtc) {
  rtc->second = 0;
  rtc->minute = 0;
  rtc->hour = 0;
  rtc->day = 0;
  rtc->month = 0;
  rtc->year = 1900;
}
