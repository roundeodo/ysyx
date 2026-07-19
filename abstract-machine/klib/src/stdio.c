#include <am.h>
#include <klib.h>
#include <klib-macros.h>
#include <stdarg.h>
#include <stdint.h>

#if !defined(__ISA_NATIVE__) || defined(__NATIVE_USE_KLIB__)

static int u2s(char *out, uintptr_t in, int base){
  char buf[32];
  int i = 0;
  int count = 0;

  if(in == 0){
    out[count++] = '0';
    return count;
  }

  while(in > 0){
    int remainder = in % base;
    buf[i++] = (remainder < 10) ? remainder + '0' : remainder - 10 + 'a';
    in /= base;
  }

  for (int j = i - 1; j >= 0; j--){
    out[count++] = buf[j];
  }
  
  return count;
}

// return the number of char that we transfered
static int i2s(char *out, long in, int base){
  if(in < 0 && base == 10){
    out[0] = '-';
    uintptr_t u = (uintptr_t)(-(in + 1)) + 1;// -2147483648 ~ 2147483647   avoid overflow, turn it into unsigned then we can add 1 safetly
    return 1 + u2s(out + 1, u, base); // minus symbol + number
  }
  return u2s(out, (uintptr_t)in, base);
}

int printf(const char *fmt, ...) {
char buf[2048];
  va_list ap;
  va_start(ap, fmt);
  int len = vsnprintf(buf, sizeof(buf), fmt, ap); 
  va_end(ap);

  int print_len = len;
  if(print_len > (int)sizeof(buf) - 1){
    print_len = (int)sizeof(buf) - 1;
  }
  for (int i = 0; i < print_len; i++)
  {
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
      // if the format ends with a single '%' we have to avoid surpass
      if (*f == '\0'){
        if (n > 0 && total_len < n - 1)
          out[total_len] = '%';
        total_len++;
        break;
      }
        // for decoding value after %
        int pad_zero = 0;
      int width = 0;
      if (*f == '0') {
        pad_zero = 1;
        f++;
      }
      while (*f >= '0' && *f <= '9') {
        width = width * 10 + (*f - '0');
        f++;
      }
      if(*f == '\0'){
        if(n > 0 && total_len < n - 1)
          out[total_len] = '%';
        total_len++;
        break;
      }
      switch (*f) {
        case 's': {
          char *s = va_arg(ap, char *);
          if (s == NULL) s = "(null)";
          size_t s_len = 0;
          const char *p = s;
          while (*p++) s_len++;

          while (width > (int)s_len) {
            if (n > 0 && total_len < n - 1) out[total_len] = ' ';
            total_len++;
            width--;
          }
          while (*s != '\0') {
            if (n > 0 && total_len < n - 1) out[total_len] = *s;
            total_len++;
            s++;
          }
          break;
        }
        case 'd': {
          long val = (long)va_arg(ap, int);

          char tmp[64];
          int actual_len = i2s(tmp, val, 10);

          int pad_len = width - actual_len;
          if(pad_len < 0)
            pad_len = 0;
          if(tmp[0] == '-' && pad_zero){
            // for "%06d" -123 should be -00123 instead of 00-123
            if(n > 0 && total_len < n-1)
              out[total_len] = '-';
            total_len++;

            for (int i = 0; i < pad_len; i++){
              if(n>0 && total_len < n-1)
                out[total_len] = '0';
              total_len++;
            }

            for (int i = 1; i < actual_len; i++){
              if(n > 0 && total_len < n-1)
                out[total_len] = tmp[i];
              total_len++;
            }
          }
          else{
            char pad_char = pad_zero ? '0' : ' ';
            for (int i = 0; i < pad_len;i++){
              if (n > 0 && total_len < n - 1)
                out[total_len] = pad_char;
              total_len++;
            }

            for (int i = 0; i < actual_len; i++){
              if(n>0 && total_len < n-1)
                out[total_len] = tmp[i];
              total_len++;
            }
          }
          break;
        }
        case 'x': {
          uintptr_t val = (uintptr_t)va_arg(ap, unsigned int);

          char tmp[64];
          int actual_len = u2s(tmp, val, 16);
          int pad_len = width - actual_len;
          if(pad_len < 0)
            pad_len = 0;

          char pad_char = pad_zero ? '0' : ' ';

          for (int i = 0; i < pad_len; i++){
            if(n > 0 && total_len < n-1)
              out[total_len] = pad_char;
            total_len++;
          }

          for (int i = 0; i < actual_len; i++){
            if(n > 0 && total_len < n-1)
              out[total_len] = tmp[i];
            total_len++;
          }
          
          break;
        }
        case '%': {
          if (n > 0 && total_len < n - 1) out[total_len] = '%';
          total_len++;
          break;
        }
        case 'p': {
            void *ptr = va_arg(ap, void *);
            uintptr_t val = (uintptr_t)ptr;
        
            if (n > 0 && total_len < n - 1) out[total_len] = '0';
            total_len++;
            if (n > 0 && total_len < n - 1) out[total_len] = 'x';
            total_len++;
        
            char tmp[32];
            int len = u2s(tmp, val, 16);
        
            for (int i = 0; i < len; i++) {
                if (n > 0 && total_len < n - 1) out[total_len] = tmp[i];
                total_len++;
            }
            break;
        }
        case 'c': {
          char ch = (char)va_arg(ap, int);

          int pad_len = width - 1;
          if(pad_len < 0)
            pad_len = 0;
          for (int i = 0; i < pad_len; i++){
            if(n>0 && total_len < n-1)
              out[total_len] = ' ';
            total_len++;
          }
          if(n>0 && total_len< n-1)
            out[total_len] = ch;
          total_len++;

          break;
        }
        default: {
          if (n > 0 && total_len < n - 1) out[total_len] = '%';
          total_len++;
          if (*f != '\0') {
            if (n > 0 && total_len < n - 1) out[total_len] = *f;
            total_len++;
          }
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
