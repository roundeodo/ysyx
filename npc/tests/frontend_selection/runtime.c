/* Minimal freestanding support for these workloads. Heap reset is per request;
 * individual frees do not reclaim memory within a request. */
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

static union { uint64_t alignment; unsigned char bytes[32768]; } arena;
static size_t used;
void arena_reset(void) { used = 0; }
void abort(void) {
  *(volatile uint32_t *)0x10002000 = 0xbad0c0de;
  for (;;) {}
}
void *malloc(size_t size) {
  size_t total = (size + 15) & ~(size_t)7;
  if (total < size || total > sizeof(arena.bytes) - used) abort();
  size_t *header = (size_t *)(arena.bytes + used); *header = size; used += total;
  return (unsigned char *)header + 8;
}
void free(void *pointer) { (void)pointer; }
void *realloc(void *old, size_t size) {
  void *value = malloc(size);
  if (old) { size_t previous = *(size_t *)((unsigned char *)old - 8); memcpy(value, old, previous < size ? previous : size); }
  return value;
}
void *memcpy(void *out, const void *in, size_t size) { unsigned char *a = out; const unsigned char *b = in; for (size_t i = 0; i < size; ++i) a[i] = b[i]; return out; }
void *memset(void *out, int value, size_t size) { unsigned char *a = out; for (size_t i = 0; i < size; ++i) a[i] = value; return out; }
void *memmove(void *out, const void *in, size_t size) { unsigned char *a = out; const unsigned char *b = in; if (a < b) return memcpy(out, in, size); for (size_t i = size; i; --i) a[i - 1] = b[i - 1]; return out; }
int memcmp(const void *a, const void *b, size_t size) { const unsigned char *x = a, *y = b; for (size_t i = 0; i < size; ++i) if (x[i] != y[i]) return x[i] - y[i]; return 0; }
size_t strlen(const char *text) { size_t n = 0; while (text[n]) ++n; return n; }
int strcmp(const char *a, const char *b) { while (*a && *a == *b) { ++a; ++b; } return (unsigned char)*a - (unsigned char)*b; }
int strncmp(const char *a, const char *b, size_t n) { for (size_t i = 0; i < n; ++i) { if (a[i] != b[i]) return (unsigned char)a[i] - (unsigned char)b[i]; if (!a[i]) break; } return 0; }
int tolower(int c) { return c >= 'A' && c <= 'Z' ? c + ('a' - 'A') : c; }
