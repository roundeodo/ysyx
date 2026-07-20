#include <am.h>
#include <klib-macros.h>

#define UART_BASE 0x10000000u

extern char _heap_start;
extern char _heap_end;

int main(const char *args);

Area heap = RANGE(&_heap_start, &_heap_end);

void putch(char ch){
    *(volatile uint8_t *)UART_BASE = (uint8_t)ch;
}

void halt(int code){
    asm volatile("mv a0, %0; ebreak" : : "r"(code));
    while(1){
    }
}

void _trm_init(void){
    int result = main("");
    halt(result);
}