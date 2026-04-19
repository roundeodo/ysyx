#include <am.h>
#include <klib-macros.h>

extern char _heap_start;
int main(const char *args);

extern char _pmem_start;
#define PMEM_SIZE (128 * 1024 * 1024)
#define PMEM_END  ((uintptr_t)&_pmem_start + PMEM_SIZE)

#define SERIAL_PORT 0x10000000

Area heap = RANGE(&_heap_start, PMEM_END);
static const char mainargs[MAINARGS_MAX_LEN] = TOSTRING(MAINARGS_PLACEHOLDER); // defined in CFLAGS

void putch(char ch) {
  *(volatile uint8_t *)SERIAL_PORT = ch;
}
// a0 is x10, which is used for transimit value(especially exit code)
void halt(int code) {
  asm volatile("mv a0, %0;ebreak" ::"r"(code));
  while (1)
    ;
}

void _trm_init() {
  int ret = main(mainargs);
  halt(ret);
}
