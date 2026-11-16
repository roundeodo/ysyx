#include <am.h>
#include <klib.h>
#include <klib-macros.h>
#include <stdarg.h>
#include <stdint.h>
#include <limits.h>
#include <test.h>

static int raw_streq(const char *a, const char *b) {
  while (*a != '\0' && *b != '\0') {
    if (*a != *b) {
      return 0;
    }

    a++;
    b++;
  }

  return *a == '\0' && *b == '\0';
}

static int call_vsprintf(char *out, const char *fmt, ...){
    va_list ap;
    va_start(ap, fmt);
    int ret = vsprintf(out, fmt, ap);
    va_end(ap);

    return ret;
}

static int call_vsnprintf(char *out, size_t n, const char *fmt, ...) {
    va_list ap; 
    va_start(ap, fmt);
    int ret = vsnprintf(out, n, fmt, ap);
    va_end(ap); 
    return ret;
}

static void test_sprintf_decimal(void){
    char buf[128];
    int ret;

    // normal positive value
    ret = sprintf(buf, "%d", 123);
    assert(ret == 3);
    assert(raw_streq(buf, "123"));

    // normal negative value
    ret = sprintf(buf, "%d", -123);
    assert(ret == 4);
    assert(raw_streq(buf, "-123"));

    // 0 
    ret = sprintf(buf, "%d", 0);
    assert(ret == 1);
    assert(raw_streq(buf, "0"));

    // width + space_padding
    ret = sprintf(buf, "%6d", -123);
    assert(ret == 6);
    assert(raw_streq(buf, "  -123"));

    // width + zero_padding
    ret = sprintf(buf, "%06d", -123);
    assert(ret == 6);
    assert(raw_streq(buf, "-00123"));

    // boundary value
    ret = sprintf(buf, "%d", INT_MAX);
    assert(ret == 10);
    assert(raw_streq(buf, "2147483647"));

    ret = sprintf(buf, "%d", INT_MIN);
    assert(ret == 11);
    assert(raw_streq(buf, "-2147483648"));

    ret = sprintf(buf, "%d", INT_MAX / 17);
    assert(ret == 9);
    assert(raw_streq(buf, "126322567"));

    ret = sprintf(buf, "%d", INT_MIN + 1);
    assert(ret == 11);
    assert(raw_streq(buf, "-2147483647"));  
}

static void test_sprintf_hex(void){
    char buf[128];
    int ret;

    // normal value
    ret = sprintf(buf, "%x", 0x1a);
    assert(ret == 2);
    assert(raw_streq(buf, "1a"));

    // width + zero_padding
    ret = sprintf(buf, "%08x", 0x1a);
    assert(ret == 8);
    assert(raw_streq(buf, "0000001a"));

    // boundary value
    ret = sprintf(buf, "%x", UINT_MAX);
    assert(ret == 8);
    assert(raw_streq(buf, "ffffffff"));

    ret = sprintf(buf, "%x", UINT_MAX / 17);
    assert(ret == 7);
    assert(raw_streq(buf, "f0f0f0f"));

    ret = sprintf(buf, "%x", INT_MAX / 17);
    assert(ret == 7);
    assert(raw_streq(buf, "7878787"));
}

static void test_sprintf_string_char_percent_pointer(void) {
    char buf[128];
    int ret;    
    
    // %s
    ret = sprintf(buf, "%s", "hello");
    assert(ret == 5);
    assert(raw_streq(buf, "hello"));    
    
    // %5s
    ret = sprintf(buf, "%5s", "hi");
    assert(ret == 5);
    assert(raw_streq(buf, "   hi"));    

    // %c  (char will be promote to int so we shoud read by va_arg(ap,int))
    ret = sprintf(buf, "%c", 'A');
    assert(ret == 1);
    assert(raw_streq(buf, "A"));    
    
    // %3c
    ret = sprintf(buf, "%3c", 'A');
    assert(ret == 3);
    assert(raw_streq(buf, "  A"));  
    
    // %%
    ret = sprintf(buf, "%%");
    assert(ret == 1);
    assert(raw_streq(buf, "%"));    
    /* mix
     * expected："hi A -7 2b %"
     *
     *   hi  -> 2
     *   space -> 1
     *   A   -> 1
     *   space -> 1
     *   -7  -> 2
     *   space -> 1
     *   2b  -> 2
     *   space -> 1
     *   %   -> 1
     *
     * total length = 12
     */
    ret = sprintf(buf, "%s %c %d %x %%", "hi", 'A', -7, 0x2b);
    assert(ret == 12);
    assert(raw_streq(buf, "hi A -7 2b %")); 
    
    // %p
    ret = sprintf(buf, "%p", (void *)0x1234);
    assert(ret == 6);
    assert(raw_streq(buf, "0x1234"));
}

static void test_snprintf_impl(void) {
    char buf[128];
    int ret;    
    
    // no cutoff
    ret = snprintf(buf, sizeof(buf), "hello");
    assert(ret == 5);
    assert(raw_streq(buf, "hello"));    

    // with cutoff   snprintf should return that length that ought to be output 
    ret = snprintf(buf, 5, "hello world");
    assert(ret == 11);
    assert(raw_streq(buf, "hell")); 

    // n = 1
    buf[0] = 'X';
    ret = snprintf(buf, 1, "abc");
    assert(ret == 3);
    assert(buf[0] == '\0'); 

    // n = 0
    buf[0] = 'X';
    ret = snprintf(buf, 0, "abc");
    assert(ret == 3);
    assert(buf[0] == 'X');  

    // format
    ret = snprintf(buf, sizeof(buf), "%06d %08x", -123, 0x1a);
    assert(ret == 15);
    assert(raw_streq(buf, "-00123 0000001a"));
}

static void test_vsprintf_impl(void) {
    char buf[128];
    int ret;    

    ret = call_vsprintf(buf, "%s %d %x", "num", -12, 0x2a); 
    /*
     * expected：
     *   "num -12 2a"
     *
     * length：
     *   num -> 3
     *   space -> 1
     *   -12 -> 3
     *   space -> 1
     *   2a -> 2
     * total length = 10
     */
    assert(ret == 10);
    assert(raw_streq(buf, "num -12 2a"));
}

static void test_vsnprintf_impl(void) {
    char buf[128];
    int ret;    
    // no cutoff
    ret = call_vsnprintf(buf, sizeof(buf), "%s %d", "abc", 123);
    assert(ret == 7);
    assert(raw_streq(buf, "abc 123"));  
    // with cutoff
    ret = call_vsnprintf(buf, 4, "abcdef");
    assert(ret == 6);
    assert(raw_streq(buf, "abc"));
}

void test_stdio(void){
    test_sprintf_decimal();
    test_sprintf_hex();
    test_sprintf_string_char_percent_pointer();
    test_snprintf_impl();
    test_vsprintf_impl();
    test_vsnprintf_impl();
}