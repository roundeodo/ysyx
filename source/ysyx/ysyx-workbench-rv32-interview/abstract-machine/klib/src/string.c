#include <klib.h>
#include <klib-macros.h>
#include <stdint.h>

#if !defined(__ISA_NATIVE__) || defined(__NATIVE_USE_KLIB__)

size_t strlen(const char *s) {
  const char *p = s;
  while(*p)
    p++;
  return p - s;
}

char *strcpy(char *dst, const char *src) {
  char *p_dst = dst;
  const char *p_src = src;
  while(1){
    *p_dst = *p_src;
    if(*p_src == '\0'){
      break;
    }
    p_dst++ ;
    p_src++;
  }
  return dst;
}

char *strncpy(char *dst, const char *src, size_t n) {
  size_t i;
  for (i = 0; i < n && src[i] != '\0'; i++)
  {
    dst[i] = src[i];
  }
  for (; i < n;i++){
    dst[i] = '\0';
  }
  return dst;
}

char *strcat(char *dst, const char *src) {
  char *ret = dst;
  while (*dst != '\0')
  {
    dst++;
  }
  while (1)
  {
    *dst = *src;
    if(*src == '\0')
      break;
    dst++;
    src++;
  }
  return ret;
}

int strcmp(const char *s1, const char *s2) {
   while(*s1 != '\0' && *s1 == *s2){
     s1++;
     s2++;
   }
   return (unsigned char)*s1 - (unsigned char)*s2;
}

int strncmp(const char *s1, const char *s2, size_t n) {
  if(n==0)
    return 0;
  size_t i = 0;
  while (*s1 != '\0' && *s1 == *s2 && i < n-1)
  {
    s1++; //be careful that we use s1++ as the result
    s2++;
    i++;
  }
   return (unsigned char)*s1 - (unsigned char)*s2;
}

void *memset(void *s, int c, size_t n) {
  void *ret = s;
  unsigned char *p = (unsigned char *)s;
  unsigned char val = (unsigned char)c;
  for (size_t i = 0; i < n;i++){
    *p = val;
    p++;
  }
  return ret;
}

void *memmove(void *dst, const void *src, size_t n) { // move need to also supply the situation that dst is overlapped with src
  unsigned char *d = (unsigned char *)dst;
  const unsigned char *s = (const unsigned char *)src;

  uintptr_t d_addr = (uintptr_t)d;
  uintptr_t s_addr = (uintptr_t)s;

  if (d == s || n == 0)
    return dst;
  if(d_addr < s_addr){
    for(size_t i = 0; i < n; i++){
      d[i] = s[i];
    }
  }
  else{
    for (size_t i = n; i > 0; i--){
      d[i - 1] = s[i - 1];
    }
  }
  return dst;
}

void *memcpy(void *out, const void *in, size_t n) { // pre-condition: out and in are not overlapped
  unsigned char *d = (unsigned char *)out;
  const unsigned char *s = (const unsigned char *)in;
  for (size_t i = 0; i < n;i++){
    d[i] = s[i];
  }
  return out;
}

int memcmp(const void *s1, const void *s2, size_t n) {
  const unsigned char *p1 = (const unsigned char *)s1;
  const unsigned char *p2 = (const unsigned char *)s2;
  for (size_t i = 0; i < n;i++){
    if(p1[i]!=p2[i]){
      return p1[i] - p2[i];
    }
  }
  return 0;
}

#endif
