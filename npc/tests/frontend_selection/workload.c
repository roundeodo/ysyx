/* CPU software proxies. Library versions and the integer-only JSON port are
 * recorded beside the vendor sources. Expected answers come from Python. */
#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include "input.h"
#include "cJSON.h"
#include "miniz_tinfl.h"

typedef uint32_t u32;
#ifdef FRONTEND_HOST
static void arena_reset(void) {}
#else
void arena_reset(void);
#endif

static u32 mix(u32 hash, u32 value) { return ((hash << 5) + hash) ^ value; }

#if WORKLOAD == 0
/* Rank-ordered byte-pair encoding. No floating point or model inference. */
static u32 encode(u32 hash, const char *text) {
  unsigned short tokens[256];
  unsigned count = (unsigned)strlen(text);
  if (count > 256) abort();
  for (unsigned i = 0; i < count; ++i) tokens[i] = (unsigned char)text[i];
  while (count > 1) {
    unsigned rank = MERGE_COUNT, position = 0;
    for (unsigned i = 0; i + 1 < count; ++i) {
      for (unsigned j = 0; j < rank; ++j) {
        if (tokens[i] == merges[j][0] && tokens[i + 1] == merges[j][1]) {
          rank = j; position = i; break;
        }
      }
    }
    if (rank == MERGE_COUNT) break;
    tokens[position] = (unsigned short)(256 + rank);
    for (unsigned i = position + 1; i + 1 < count; ++i) tokens[i] = tokens[i + 1];
    --count;
  }
  hash = mix(hash, count);
  for (unsigned i = 0; i < count; ++i) hash = mix(hash, tokens[i]);
  return hash;
}

static u32 visit(u32 hash, const cJSON *node) {
  for (; node; node = node->next) {
    if (node->string) hash = encode(hash, node->string);
    if (cJSON_IsString(node)) hash = encode(mix(hash, 1), node->valuestring);
    else if (cJSON_IsNumber(node)) hash = mix(mix(hash, 2), (u32)node->valueint);
    else if (cJSON_IsBool(node)) hash = mix(mix(hash, 3), (u32)cJSON_IsTrue(node));
    else if (cJSON_IsNull(node)) hash = mix(hash, 4);
    else hash = visit(mix(hash, cJSON_IsArray(node) ? 5 : 6), node->child);
  }
  return hash;
}

u32 run(void) {
  u32 hash = 5381;
  for (unsigned i = 0; i < REPEATS; ++i) {
    arena_reset();
    cJSON *root = cJSON_Parse((const char *)input);
    if (!root) abort();
    hash = visit(hash, root);
    cJSON_Delete(root);
  }
  return hash;
}
#elif WORKLOAD == 1
/* Quantized tensor loader: DEFLATE, signed INT4 conversion and blocked layout. */
static unsigned char unpacked_file[RAW_BYTES];
static signed char tensor[RAW_BYTES * 2];
u32 run(void) {
  u32 hash = 5381;
  for (unsigned repeat = 0; repeat < REPEATS; ++repeat) {
    size_t size = tinfl_decompress_mem_to_mem(unpacked_file, sizeof(unpacked_file),
                                            input, sizeof(input), TINFL_FLAG_PARSE_ZLIB_HEADER);
    if (size != RAW_BYTES) abort();
    for (unsigned i = 0; i < RAW_BYTES; ++i) {
      int low = (unpacked_file[i] & 15) - ((unpacked_file[i] & 8) ? 16 : 0);
      int high = (unpacked_file[i] >> 4) - ((unpacked_file[i] & 128) ? 16 : 0);
      int bias = (int)(i & 15) - 7;
      low = low * 8 + bias; high = high * 8 - bias;
      if (low < -48) low = -48;
      if (low > 47) low = 47;
      if (high < -48) high = -48;
      if (high > 47) high = 47;
      tensor[2 * i] = low; tensor[2 * i + 1] = high;
    }
    for (unsigned block = 0; block < RAW_BYTES * 2; block += 64)
      for (unsigned lane = 0; lane < 8; ++lane)
        for (unsigned row = 0; row < 8; ++row)
          hash = mix(hash, (unsigned char)tensor[block + row * 8 + lane]);
  }
  return hash;
}
#else
/* Runtime command graph. Dependencies are checked before executing each node. */
typedef u32 (*operator_fn)(u32, u32);
static u32 add(u32 a, u32 b) { return a + b; }
static u32 rotate(u32 a, u32 b) { unsigned n = b & 31; return (a << n) | (a >> ((32 - n) & 31)); }
static u32 clip(u32 a, u32 b) { int v = (int)(a & 65535) - 32768; int bound = (b & 255) + 1; return (u32)(v < -bound ? -bound : v > bound ? bound : v); }
static u32 select_bits(u32 a, u32 b) { return ((a & 0x55555555u) << 1) | ((b & 0xaaaaaaaau) >> 1); }
static u32 xor_shift(u32 a, u32 b) { a ^= a << 13; a ^= a >> 17; a ^= a << 5; return a ^ b; }
static u32 popcount(u32 a, u32 b) { unsigned count = 0; for (; a; a &= a - 1) ++count; return count + b; }
static u32 relu(u32 a, u32 b) { return (int)a < 0 ? b : a + b; }
static u32 maximum(u32 a, u32 b) { return a > b ? a : b; }
static operator_fn operators[] = {add, rotate, clip, select_bits, xor_shift, popcount, relu, maximum};

static int field(const cJSON *node, const char *name) {
  const cJSON *value = cJSON_GetObjectItemCaseSensitive(node, name);
  if (!cJSON_IsNumber(value)) abort();
  return value->valueint;
}

u32 run(void) {
  u32 hash = 5381;
  for (unsigned repeat = 0; repeat < REPEATS; ++repeat) {
    arena_reset();
    cJSON *root = cJSON_Parse((const char *)input);
    const cJSON *commands = cJSON_GetObjectItemCaseSensitive(root, "commands");
    u32 values[64] = {0}, present[64] = {0};
    if (!cJSON_IsArray(commands)) abort();
    unsigned remaining = (unsigned)cJSON_GetArraySize(commands);
    while (remaining) {
      unsigned progress = 0;
      for (const cJSON *node = commands->child; node; node = node->next) {
        int id = field(node, "id"), left = field(node, "left"), right = field(node, "right");
        int op = field(node, "op"), immediate = field(node, "value");
        if ((unsigned)id >= 64 || (unsigned)op >= 8 || left >= 64 || right >= 64) abort();
        if (present[id] || (left >= 0 && !present[left]) || (right >= 0 && !present[right])) continue;
        u32 a = left >= 0 ? values[left] : (u32)immediate;
        u32 b = right >= 0 ? values[right] : (u32)(immediate ^ 0x31);
        values[id] = operators[op](a, b); present[id] = 1;
        hash = mix(mix(hash, id), values[id]);
        --remaining; ++progress;
      }
      if (!progress) abort();
    }
    cJSON_Delete(root);
  }
  return hash;
}
#endif
