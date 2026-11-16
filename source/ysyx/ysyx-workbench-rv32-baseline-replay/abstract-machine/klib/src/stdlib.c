#include <am.h>
#include <klib.h>
#include <klib-macros.h>

#if !defined(__ISA_NATIVE__) || defined(__NATIVE_USE_KLIB__)
static unsigned long int next = 1;

int rand(void) {
  // RAND_MAX assumed to be 32767
  next = next * 1103515245 + 12345;
  return (unsigned int)(next/65536) % 32768;
}

void srand(unsigned int seed) {
  next = seed;
}

int abs(int x) {
  return (x < 0 ? -x : x);
}

int atoi(const char* nptr) {
  int x = 0;
  while (*nptr == ' ') { nptr ++; }
  while (*nptr >= '0' && *nptr <= '9') {
    x = x * 10 + *nptr - '0';
    nptr ++;
  }
  return x;
}

extern Area heap;

// manage memory  need to record how much u have dispatched and what u gonna dispatch
void *malloc(size_t size) {
  // On native, malloc() will be called during initializaion of C runtime.
  // Therefore do not call panic() here, else it will yield a dead recursion:
  //   panic() -> putchar() -> (glibc) -> malloc() -> panic()
#if !(defined(__ISA_NATIVE__) && defined(__NATIVE_USE_KLIB__))
  static uintptr_t current_addr = 0; // has to be static so that it's a manageable variable
  if(current_addr == 0){
    current_addr = (uintptr_t)heap.start;
  }

  // alignment
  current_addr = (current_addr + 7) & ~7; //align to 8
  void *ret = (void *)current_addr;
  current_addr += size;
  if(current_addr > (uintptr_t)heap.end){
    panic("out of memory in klib malloc");
  }
  return ret;

#endif
  return NULL;
}

void free(void *ptr) {
}

#endif
