// 通过项目自己的 AM CTE 和 trap.S 验证 C 层事件派发与寄存器恢复。
#include <am.h>

static volatile unsigned timer_count;
static volatile unsigned yield_count;

void putch(char character) { (void)character; }

void halt(int code) {
  asm volatile("mv a0, %0; ebreak" : : "r"(code) : "a0", "memory");
  for (;;) {}
}

static void check(bool condition, int code) {
  if (!condition) halt(code);
}

static void set_compare(uint32_t low, uint32_t high) {
  volatile uint32_t *compare = (volatile uint32_t *)0x02004000;
  compare[0] = UINT32_MAX;
  compare[1] = high;
  compare[0] = low;
}

static void arm_timer(void) {
  uint32_t now = *(volatile uint32_t *)0x02000048;
  set_compare(now + 200, 0);
}

static Context *handle_event(Event event, Context *context) {
  check(!ienabled(), 20);
  if (event.event == EVENT_IRQ_TIMER) {
    check(context->mcause == 0x80000007u, 21);
    timer_count++;
    if (timer_count < 5) arm_timer();
    else set_compare(UINT32_MAX, UINT32_MAX);
  } else if (event.event == EVENT_YIELD) {
    yield_count++;
  } else {
    halt(22);
  }
  return context;
}

int main(void) {
  iset(false);
  check(!ienabled(), 23);
  check(cte_init(handle_event), 24);
  asm volatile("csrw mie, %0" : : "r"(128) : "memory");
  arm_timer();
  iset(true);
  check(ienabled(), 25);
  yield();
  check(yield_count == 1, 26);
  // 值跨 C 调用与异步中断存活，检查上下文恢复没有破坏循环状态。
  volatile unsigned *progress = (volatile unsigned *)0x80010000;
  unsigned iterations = 0;
  while (timer_count < 5) {
    *progress = ++iterations;
    check(*progress == iterations, 27);
  }
  iset(false);
  check(!ienabled() && timer_count == 5, 28);
  halt(0);
}

// AM 的失败分支会调用 printf；测试用 halt 的退出码报告错误。
int printf(const char *format, ...) {
  (void)format;
  return 0;
}
