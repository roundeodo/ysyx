#include <am.h>
#include <klib.h>
#include <klib-macros.h>
#include <stdint.h>
#include <test.h>

#define N 32

static uint8_t data[N];

static uint8_t src_data[N];
static uint8_t dst_data[N];


static void reset(void) {
  for (int i = 0; i < N; i++) {
    data[i] = i + 1;
  }
}

static void reset_src_dst(void){
  for (int i = 0; i < N; i++){
    src_data[i] = (uint8_t)(0x80 + i);
    dst_data[i] = (uint8_t)(i + 1);
  }
}

static void check_seq(int l, int r, uint8_t val) {
  for (int i = l; i < r; i++) {
    assert(data[i] == val + i - l);
  }
}

static void check_eq(int l, int r, uint8_t val) {
  for (int i = l; i < r; i++) {
    assert(data[i] == val);
  }
}

static void check_raw_bytes_eq(const uint8_t *a, const uint8_t *b, size_t n){
  for (size_t i = 0; i < n; i++){
    assert(a[i] == b[i]);
  }
}

static void ref_memmove(uint8_t *dst, const uint8_t *src, size_t n){
  uint8_t temp[N];

  for (size_t i = 0; i < n;i++){
    temp[i] = src[i];
  }

  for (size_t i = 0; i < n;i++){
    dst[i] = temp[i];
  }
}

static void test_memset_impl(void){
  for (int l = 0; l <= N;l++){
    for (int r = l; r <= N;r++){
      reset();
      uint8_t val = (uint8_t)((l + r + 7) & 0xff);
      // set the value of the segment
      void *ret = memset(data + l, val, r - l);
      assert(ret == data + l);
      // left continue region
      check_seq(0, l, 1);
      // middle set region
      check_eq(l, r, val);
      // right continue region
      check_seq(r, N, r + 1);
    }
  }
}

static void test_memcpy_impl(void){
  // memcpy require that there is not overlap between src and dst
  for (int l = 0; l <= N; l++){
    for (int r = l; r <= N; r++){
      reset_src_dst();
      void *ret = memcpy(dst_data + l, src_data + l, r - l);
      assert(ret == dst_data + l);

      for (int i = 0; i < l; i++){
        assert(dst_data[i] == (uint8_t)(i + 1));
      }

      for (int i = l; i < r; i++){
        assert(dst_data[i] == src_data[i]);
      }

      for (int i = r; i < N; i++){
        assert(dst_data[i] == (uint8_t)(i+1));
      }
    }
  }
}

static void test_memmove_impl(void){
  // memmove need to support overlap
  uint8_t actual[N];
  uint8_t expected[N];

  for (int src_off = 0; src_off <= N; src_off++){
    for (int dst_off = 0; dst_off <= N; dst_off++){
      for (int len = 0; len <= N; len++){
        if(src_off + len > N)
          continue;
        if(dst_off + len > N)
        continue;

        for (int i = 0; i < N; i++){
          actual[i] = (uint8_t)(i + 1);
          expected[i] = (uint8_t)(i + 1);
        }

        void *ret = memmove(actual + dst_off, actual + src_off, len);
        ref_memmove(expected + dst_off, expected + src_off, len);
        assert(ret == actual + dst_off); // have to return target address
        check_raw_bytes_eq(actual, expected, N);
      }
    }
  }
}

static void test_strcpy_impl(void){
  char buf[32];

  for (int i = 0; i < 32; i++){
    buf[i] = (char)0xaa;
  }

  char *ret = strcpy(buf, "abc");
  assert(ret == buf);
  assert(buf[0] == 'a');
  assert(buf[1] == 'b');
  assert(buf[2] == 'c');
  assert(buf[3] == '\0');

  assert((unsigned char)buf[4] == 0xaa);
}


static void test_strncpy_impl(void){
  char buf[16];

  // length < n
  for (int i = 0; i < 16;i++){
    buf[i] = (char)0xaa;
  }
  char *ret = strncpy(buf, "abc", 6);
  assert(ret == buf);
  assert(buf[0] == 'a');
  assert(buf[1] == 'b');
  assert(buf[2] == 'c');
  assert(buf[3] == '\0');
  assert(buf[4] == '\0');
  assert(buf[5] == '\0');

  assert((unsigned char)buf[6] == 0xaa);

  // length > n
  for (int i = 0; i < 16; i++){
    buf[i] = (char)0xaa;
  }
  ret = strncpy(buf, "abcdef", 3);
  assert(ret == buf);
  assert(buf[0] == 'a');
  assert(buf[1] == 'b');
  assert(buf[2] == 'c');

  assert((unsigned char)buf[3] == 0xaa); // transfer to unsigned because char can be signed/unsigned in different platform

  // length = 0
  for (int i = 0; i < 16; i++){
    buf[i] = (char)0xaa;
  }

  ret = strncpy(buf, "abc", 0);
  assert(ret == buf);
  assert((unsigned char)buf[0] == 0xaa);
}

static void test_strcat_impl(void){
  char buf[32];

  for (int i = 0; i < 32; i++){
    buf[i] = (char)0xaa;
  }
  buf[0] = 'a';
  buf[1] = 'b';
  buf[2] = '\0';

  char *ret = strcat(buf, "cd");

  assert(ret == buf);
  assert(buf[0] == 'a');
  assert(buf[1] == 'b');
  assert(buf[2] == 'c');
  assert(buf[3] == 'd');
  assert(buf[4] == '\0');
}

void test_memory(void){
  test_memset_impl();
  test_memcpy_impl();
  test_memmove_impl();
  test_strcpy_impl();
  test_strncpy_impl();
  test_strcat_impl();
}