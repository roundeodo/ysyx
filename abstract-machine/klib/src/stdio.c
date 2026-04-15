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
  out[count++] = '-'; 
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
    out[count++] = buf[j];
  }
  return count;
}

int printf(const char *fmt, ...) {
char buf[2048];
  va_list ap;
  va_start(ap, fmt);
  int len = vsnprintf(buf, sizeof(buf), fmt, ap); 
  va_end(ap);
  for (int i = 0; i < len && i < sizeof(buf); i++) {
    putch(buf[i]); //to device
  }
  return len;
}

int vsprintf(char *out, const char *fmt, va_list ap) {
  return vsnprintf(out, (size_t)-1, fmt, ap);
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
  va_list ap;
  va_start(ap, fmt);
  int len = vsnprintf(out, n, fmt, ap);
  va_end(ap);
  return len;
}

int vsnprintf(char *out, size_t n, const char *fmt, va_list ap) {
  size_t total_len = 0; 
  const char *f = fmt;

  while (*f != '\0') {
    if (*f != '%') {
      if (n > 0 && total_len < n - 1) out[total_len] = *f;
      total_len++;
      f++;
    } else {
      f++; 
      switch (*f) {
        case 's': {
          char *s = va_arg(ap, char *);
          if (s == NULL) s = "(null)";
          while (*s != '\0') {
            if (n > 0 && total_len < n - 1) out[total_len] = *s;
            total_len++;
            s++;
          }
          break;
        }
        case 'd': {
          long d = (long)va_arg(ap, int);
          char tmp[32];
          int len = i2s(tmp, d, 10); 
          for (int i = 0; i < len; i++) {
            if (n > 0 && total_len < n - 1) out[total_len] = tmp[i];
            total_len++;
          }
          break;
        }
        case 'x': { 
          unsigned long x = va_arg(ap, unsigned int);
          char tmp[32];
          int len = i2s(tmp, (long)x, 16);
          for (int i = 0; i < len; i++) {
            if (n > 0 && total_len < n - 1) out[total_len] = tmp[i];
            total_len++;
          }
          break;
        }
        case '%': {
          if (n > 0 && total_len < n - 1) out[total_len] = '%';
          total_len++;
          break;
        }
        default: {
          if (n > 0 && total_len < n - 1) out[total_len] = '%';
          total_len++;
          if (n > 0 && total_len < n - 1) out[total_len] = *f;
          total_len++;
          break;
        }
      }
      f++;
    }
  }

  if (n > 0) {
    if (total_len < n) out[total_len] = '\0';
    else out[n - 1] = '\0';
  }
  return (int)total_len;
}
#endif
