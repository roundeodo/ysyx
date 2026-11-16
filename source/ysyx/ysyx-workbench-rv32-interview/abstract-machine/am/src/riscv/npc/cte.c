#include <am.h>
#include <riscv/riscv.h>
#include <klib.h>

static Context* (*user_handler)(Event, Context*) = NULL;

Context* __am_irq_handle(Context *c) {
  if (user_handler) {
    Event ev = {0};
    switch (c->mcause) {
      case ((uintptr_t)1 << (__riscv_xlen - 1)) | 7:
        // 硬件中断的 mepc 已经是恢复地址，不能像 ecall 一样加 4。
        // 用户处理程序负责重设 mtimecmp，再返回当前或调度后的上下文。
        ev.event = EVENT_IRQ_TIMER;
        break;

      case 11:
        if(c->GPR1 == (uintptr_t)-1){
          ev.event = EVENT_YIELD;
        }else{
          ev.event = EVENT_SYSCALL;
        }
        c->mepc += 4;
        break;

      default:
        ev.event = EVENT_ERROR;
        break;
      }

    c = user_handler(ev, c);
    assert(c != NULL);
  }

  return c;
}

extern void __am_asm_trap(void);

bool cte_init(Context*(*handler)(Event, Context*)) {
  // initialize exception entry
  asm volatile("csrw mtvec, %0" : : "r"(__am_asm_trap));

  // register event handler
  user_handler = handler;

  return true;
}

Context *kcontext(Area kstack, void (*entry)(void *), void *arg) {
  Context *c = (Context *)kstack.end - 1;
  memset(c, 0, sizeof(Context));

  c->mepc = (uintptr_t)entry;
  c->mstatus = 0x1800;
  c->gpr[10] = (uintptr_t)arg;

  return c;
}

void yield() {
#ifdef __riscv_e
  asm volatile("li a5, -1; ecall");
#else
  asm volatile("li a7, -1; ecall");
#endif
}

bool ienabled() {
  uintptr_t mstatus;
  asm volatile("csrr %0, mstatus" : "=r"(mstatus));
  return (mstatus & 8) != 0;
}

void iset(bool enable) {
  if (enable) {
    asm volatile("csrsi mstatus, 8" : : : "memory");
  } else {
    asm volatile("csrci mstatus, 8" : : : "memory");
  }
}
