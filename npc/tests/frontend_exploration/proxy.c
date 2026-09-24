/* Integer CPU proxies, not end-to-end AI inference. Inputs/reference are generated
 * independently in Python; no benchmark-specific ISA or software timing reads. */
#include "input.h"
typedef unsigned int u32;
static u32 mix(u32 hash, u32 value) { return ((hash << 5) + hash) ^ value; }

#if WORKLOAD == 0
/* Greedy lexical tokenization with keyword lookup and numeric accumulation. */
static const char *const vocabulary[] = {
  "model", "token", "input", "output", "sample", "cache", "tensor", "layer",
  "true", "false", "load", "store", "decode", "prefill", "queue", "wait"
};
static int letter(unsigned char c) {
  return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_';
}
u32 run(void) {
  u32 hash = 5381;
  for (u32 repeat = 0; repeat < REPEATS; ++repeat) {
    u32 i = 0;
    while (i < INPUT_COUNT) {
      unsigned char c = input[i];
      if (c == ' ' || c == '\n' || c == '\t') { ++i; continue; }
      if (letter(c)) {
        u32 begin = i++, word = 0, token = 256;
        while (i < INPUT_COUNT && (letter(input[i]) || (input[i] >= '0' && input[i] <= '9'))) ++i;
        for (u32 j = begin; j < i; ++j) word = mix(word, input[j]);
        for (u32 k = 0; k < 16; ++k) {
          u32 j = 0;
          while (begin + j < i && vocabulary[k][j] && vocabulary[k][j] == input[begin+j]) ++j;
          if (begin+j == i && vocabulary[k][j] == 0) { token = k; break; }
        }
        hash = mix(mix(hash, token), word);
      } else if (c >= '0' && c <= '9') {
        u32 value = 0;
        do { value = (value << 3) + (value << 1) + input[i++] - '0'; }
        while (i < INPUT_COUNT && input[i] >= '0' && input[i] <= '9');
        hash = mix(mix(hash, 257), value);
      } else { hash = mix(hash, c); ++i; }
    }
  }
  return hash;
}
#elif WORKLOAD == 1
/* Signed INT4 unpack, integer bias, saturation and blocked lane permutation. */
static signed char unpacked[INPUT_COUNT * 2];
u32 run(void) {
  u32 hash = 5381;
  for (u32 repeat = 0; repeat < REPEATS; ++repeat) {
    for (u32 i = 0; i < INPUT_COUNT; ++i) {
      int a = (input[i] & 15) ^ 8, b = (input[i] >> 4) ^ 8;
      a = ((a - 8) * 4) + (int)(i & 7) - 3;
      b = ((b - 8) * 4) - (int)(i & 7) + 3;
      if (a < -24) a = -24; if (a > 23) a = 23;
      if (b < -24) b = -24; if (b > 23) b = 23;
      unpacked[2*i] = a; unpacked[2*i+1] = b;
    }
    for (u32 block = 0; block < INPUT_COUNT * 2; block += 32)
      for (u32 lane = 0; lane < 4; ++lane)
        for (u32 row = 0; row < 8; ++row)
          hash = mix(hash, (unsigned char)unpacked[block+4*row+lane]);
  }
  return hash;
}
#else
/* Runtime command dispatch through function pointers, with dependent state. */
static __attribute__((noinline)) u32 op0(u32 x, u32 y) { return x + y; }
static __attribute__((noinline)) u32 op1(u32 x, u32 y) { return x ^ (y << 3); }
static __attribute__((noinline)) u32 op2(u32 x, u32 y) { return x < y ? x + 7 : x - y; }
static __attribute__((noinline)) u32 op3(u32 x, u32 y) { return (x >> 1) | (y << 24); }
static __attribute__((noinline)) u32 op4(u32 x, u32 y) { return (x & 255) == y ? x + 1 : x ^ y; }
static __attribute__((noinline)) u32 op5(u32 x, u32 y) { return (x << 2) + y; }
static __attribute__((noinline)) u32 op6(u32 x, u32 y) { return x & 1 ? x + y : x - y; }
static __attribute__((noinline)) u32 op7(u32 x, u32 y) { return (x >> 3) ^ (y + 17); }
static u32 (*const operations[])(u32, u32) = {op0,op1,op2,op3,op4,op5,op6,op7};
u32 run(void) {
  u32 state[8] = {1,2,3,4,5,6,7,8}, hash = 5381;
  for (u32 repeat = 0; repeat < REPEATS; ++repeat)
    for (u32 i = 0; i < INPUT_COUNT; ++i) {
      u32 command = input[i], slot = (command >> 3) & 7;
      state[slot] = operations[command & 7](state[slot], (command >> 2) + state[(slot+1)&7]);
      hash = mix(hash, state[slot]);
    }
  return hash;
}

#endif
