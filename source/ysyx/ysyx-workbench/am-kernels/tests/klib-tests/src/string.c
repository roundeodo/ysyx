#include <am.h>
#include <klib.h>
#include <klib-macros.h>
#include <stdint.h>
#include <test.h>

static void test_strlen_impl(void){
    assert(strlen("") == 0);
    assert(strlen("a") == 1);
    assert(strlen("hello") == 5);

    char s[] = {'a', 'b', '\0', 'c', 'd', '\0'};
    assert(strlen(s) == 2);
}

static void test_strcmp_impl(void){
    assert(strcmp("", "") == 0);
    assert(strcmp("abc", "abc") == 0);

    assert(strcmp("abc", "abd") < 0);
    assert(strcmp("abd", "abc") > 0);

    assert(strcmp("abc", "ab") > 0);
    assert(strcmp("ab", "abc") < 0);

    // test unsigned char  because 0x80 might be treated as negative value in some platform
    char high[] = {(char)0x80, '\0'};
    char low[] = {(char)0x01, '\0'};

    assert(strcmp(high, low) > 0);
    assert(strcmp(low, high) < 0);
}

static void test_strncmp_impl(void){
    // compare all
    assert(strncmp("abc", "abc", 3) == 0);
    // compare part
    assert(strncmp("abc", "abd", 2) == 0);
    // compare all 
    assert(strncmp("abc", "abd", 3) < 0);
    // compare none
    assert(strncmp("abc", "abd", 0) == 0);
    assert(strncmp("", "a", 0) == 0);
    // compare prefix
    assert(strncmp("abc", "ab", 3) > 0);
    assert(strncmp("ab", "abc", 3) < 0);
    // compare ungisned char
    char high[] = { (char)0x80, '\0' };
    char low[]  = { (char)0x01, '\0' };
    assert(strncmp(high, low, 1) > 0);
    assert(strncmp(low, high, 1) < 0);
}

static void test_memcmp_impl(void) {
    uint8_t a[] = { 1, 2, 3, 4 };
    uint8_t b[] = { 1, 2, 3, 4 };
    uint8_t c[] = { 1, 2, 5, 4 };
    uint8_t d[] = { 1, 2, 1, 4 };   

    // compare none
    assert(memcmp(a, c, 0) == 0);   
    assert(memcmp(a, b, 4) == 0);   
    // compare first two
    assert(memcmp(a, c, 2) == 0);   
    // compare first three
    assert(memcmp(a, c, 4) < 0);    
    assert(memcmp(a, d, 4) > 0);    
    // test unsigned char
    uint8_t high[] = { 0x80 };
    uint8_t low[]  = { 0x01 };  
    assert(memcmp(high, low, 1) > 0);
    assert(memcmp(low, high, 1) < 0);
}

void test_string(void){
    test_strlen_impl();
    test_strcmp_impl();
    test_strncmp_impl();
    test_memcmp_impl();
}