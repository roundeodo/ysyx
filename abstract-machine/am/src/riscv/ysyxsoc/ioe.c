#include <am.h>
#include <klib-macros.h>

void __am_timer_init(void);
void __am_timer_rtc(AM_TIMER_RTC_T *rtc);
void __am_timer_uptime(AM_TIMER_UPTIME_T *uptime);

typedef void (*io_handler_t)(void *buf);

static void __am_timer_config(AM_TIMER_CONFIG_T *config) {
  config->present = true;
  config->has_rtc = false;
}

static void unsupported_io_access(void *buf) {
  (void)buf;
  panic("access unsupported ysyxsoc IO register");
}

static io_handler_t io_handler_table[128] = {
  [AM_TIMER_CONFIG] = (io_handler_t)__am_timer_config,
  [AM_TIMER_RTC] = (io_handler_t)__am_timer_rtc,
  [AM_TIMER_UPTIME] = (io_handler_t)__am_timer_uptime,
};

bool ioe_init(void) {
  for (int i = 0; i < LENGTH(io_handler_table); i++) {
    if (io_handler_table[i] == NULL) {
      io_handler_table[i] = unsupported_io_access;
    }
  }

  __am_timer_init();
  return true;
}

void ioe_read(int reg, void *buf) {
  io_handler_table[reg](buf);
}

void ioe_write(int reg, void *buf) {
  io_handler_table[reg](buf);
}
