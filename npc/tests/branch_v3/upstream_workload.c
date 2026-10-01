/* Upstream JSON tokenization and model-metadata decompression. The input bytes
 * remain unchanged. This does not execute a neural model or floating-point math. */
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include "input.h"
#if WORKLOAD == 0
#define JSMN_STRICT
#define JSMN_STATIC
#include "jsmn.h"
static jsmntok_t tokens[REPEATS][256];
static int counts[REPEATS];
#else
#include "miniz_tinfl.h"
static unsigned char output[REPEATS][RAW_BYTES];
#endif
static uint32_t mix(uint32_t h, unsigned v) { return (h << 5) + h ^ v; }
void run_workload(void) {
  for (unsigned repeat=0;repeat<REPEATS;repeat++) {
#if WORKLOAD == 0
    jsmn_parser parser;
    jsmn_init(&parser);
    int count=jsmn_parse(&parser,(const char*)input,INPUT_BYTES,tokens[repeat],256);
    if(count<0) abort();
    counts[repeat]=count;
#else
    size_t count=tinfl_decompress_mem_to_mem(output[repeat],RAW_BYTES,input,INPUT_BYTES,TINFL_FLAG_PARSE_ZLIB_HEADER);
    if(count!=RAW_BYTES) abort();
#endif
  }
}
/* Output verification is outside the scored RTL window. Preserve every call's
 * result so an early faulty invocation cannot be hidden by a later overwrite. */
uint32_t validate_workload(void) {
  uint32_t h=5381;
  for(unsigned repeat=0;repeat<REPEATS;repeat++) {
#if WORKLOAD == 0
    h=mix(h,(unsigned)counts[repeat]);
    for(int t=0;t<counts[repeat];t++) {
      const jsmntok_t *token=&tokens[repeat][t];
      h=mix(h,(unsigned)token->type);
      h=mix(h,(unsigned)(token->end-token->start));
      for(int i=token->start;i<token->end;i++) h=mix(h,input[i]);
    }
#else
    for(unsigned i=0;i<RAW_BYTES;i++) h=mix(h,output[repeat][i]);
#endif
  }
  return h;
}
uint32_t run(void) {
  run_workload();
  return validate_workload();
}
