#include <am.h>
#include <klib-macros.h>
#include <uart.h>

extern char _heap_start;
extern char _heap_end;

int main(const char *args);

#ifndef MAINARGS
#define MAINARGS ""
#endif

Area heap = RANGE(&_heap_start, &_heap_end);

void putch(char ch) {
  uart_putc(ch);
}

void halt(int code){
    asm volatile("mv a0, %0; ebreak" : : "r"(code));
    while(1){
    }
}

void _trm_init(void){
    uart_init();
    int result = main(MAINARGS);
    halt(result);
}
