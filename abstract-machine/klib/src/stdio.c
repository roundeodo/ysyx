#include <am.h>
#include <klib.h>
#include <klib-macros.h>
#include <stdarg.h>

#if !defined(__ISA_NATIVE__) || defined(__NATIVE_USE_KLIB__)

static int i2s(char *out, long in, int base){
  char buf[32];
  int i = 0;
  int count = 0;

  if(in == 0){
    *out = '0';
    return 1;
  }

  unsigned long u_in = (unsigned long)in;
  if(in < 0 && base == 10){
    *out = '-';
    out++;
    count++;
    u_in = (unsigned long)-(in + 1) + 1; // -2147483648 ~ 2147483647   avoid overflow, turn it into unsigned then we can add 1 safetly
  }
  else{
    u_in = (unsigned long)in;
  }

  while(u_in > 0){
    int remainder = u_in % base;
    buf[i] = (remainder < 10) ? (remainder + '0') : (remainder - 10 + 'a');
    i++;
    u_in = u_in / base;
  }

  for (int j = i - 1; j >= 0; j--){
    *out++ = buf[j];
    count++;
  }
  return count;
}

int printf(const char *fmt, ...) {
  panic("Not implemented");
}

int vsprintf(char *out, const char *fmt, va_list ap) {
  char *p = out;
  const char *f = fmt;
  while(*f != '\0'){
    if(*f != '%'){
      *p++ = *f++;
    }
    else{
      f++;
      switch(*f){
        case 's':{
          char *s = va_arg(ap, char *);
          while(*s)
            *p++ = *s++;
          break;
        }
        case 'd':{
          int d = va_arg(ap, int);
          int len = i2s(p, (long)d, 10);
          p = p + len;
          break;
        }
        case '%':{
          *p = '%';
          p++;
        }
        default:{
          *p = '%';
          p++;
          *p = *f;
          p++;
          break;
        }
      }
      f++;
    }
  }
  *p = '\0';
  return p - out; //length
}

int sprintf(char *out, const char *fmt, ...) {
  va_list ap;
  int n;
  va_start(ap, fmt);
  n = vsprintf(out, fmt, ap);
  va_end(ap);
  return n;
}

int snprintf(char *out, size_t n, const char *fmt, ...) {
  panic("Not implemented");
}

int vsnprintf(char *out, size_t n, const char *fmt, va_list ap) {
  panic("Not implemented");
}

#endif
