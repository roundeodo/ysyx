/* Unmodified upstream parsers; six distinct real metadata requests per stream.
 * Each output remains available for verification after the measured interval. */
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include "input.h"
#if WORKLOAD == 0
#define JSMN_STRICT
#define JSMN_STATIC
#include "jsmn.h"
static jsmntok_t tokens[CALL_COUNT][TOKEN_CAPACITY];
static int counts[CALL_COUNT];
#else
#include "miniz_tinfl.h"
static unsigned char output[OUTPUT_BYTES];
#endif
static void request(unsigned index) {
#if WORKLOAD == 0
  jsmn_parser parser;
  jsmn_init(&parser);
  counts[index] = jsmn_parse(&parser, (const char *)input + input_offset[index],
                            input_length[index], tokens[index], TOKEN_CAPACITY);
  if (counts[index] < 0) abort();
#else
  size_t bytes = tinfl_decompress_mem_to_mem(output + output_offset[index],
      raw_length[index], input + input_offset[index], input_length[index],
      TINFL_FLAG_PARSE_ZLIB_HEADER);
  if (bytes != raw_length[index]) abort();
#endif
}
void warm_prefix(void) {
  for (unsigned index = 0; index < FIRST_MEASURED; index++) request(index);
}
void run_workload(void) {
  for (unsigned index = FIRST_MEASURED; index < CALL_COUNT; index++) request(index);
}
static uint32_t mix(uint32_t hash, unsigned value) {
  return (hash << 5) + hash ^ value;
}
uint32_t validate_workload(void) {
  uint32_t hash = 5381;
  for (unsigned index = 0; index < CALL_COUNT; index++) {
#if WORKLOAD == 0
    hash = mix(hash, counts[index]);
    for (int t = 0; t < counts[index]; t++) {
      const jsmntok_t *token = &tokens[index][t];
      hash = mix(hash, token->type);
      hash = mix(hash, token->end - token->start);
      for (int i = token->start; i < token->end; i++)
        hash = mix(hash, input[input_offset[index] + i]);
    }
#else
    for (unsigned i = 0; i < raw_length[index]; i++)
      hash = mix(hash, output[output_offset[index] + i]);
#endif
  }
  return hash;
}
uint32_t run(void) {
  warm_prefix();
  run_workload();
  return validate_workload();
}
