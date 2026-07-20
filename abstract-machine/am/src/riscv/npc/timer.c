#include <am.h>

#define RTC_ADDR_LO 0x02000048
#define RTC_ADDR_HI 0x0200004c

void __am_timer_init() {
}

void __am_timer_uptime(AM_TIMER_UPTIME_T *uptime) {
  uint32_t lo = *(volatile uint32_t *)RTC_ADDR_LO;
  uint32_t hi = *(volatile uint32_t *)RTC_ADDR_HI;

  uptime->us = ((uint64_t)hi << 32) | lo;
}

void __am_timer_rtc(AM_TIMER_RTC_T *rtc) {
  rtc->second = 0;
  rtc->minute = 0;
  rtc->hour   = 0;
  rtc->day    = 0;
  rtc->month  = 0;
  rtc->year   = 1900;
}
