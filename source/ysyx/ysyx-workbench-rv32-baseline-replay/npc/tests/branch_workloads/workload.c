/* Integer software paths surrounding inference; each result is checked by Python. */
#include <stdint.h>
#include <stddef.h>
#include "input.h"
#if WORKLOAD == 0
#include "re.h"
#elif WORKLOAD == 1
#include "ini.h"
#endif

static uint32_t mix(uint32_t hash, uint32_t value) { return hash * 33u ^ value; }
#if WORKLOAD == 1
static uint32_t text_hash(uint32_t hash, const char *text) {
  while (*text) hash = mix(hash, (unsigned char)*text++);
  return mix(hash, 0);
}
static int config_entry(void *user, const char *section, const char *name, const char *value) {
  uint32_t *hash = user;
  *hash = text_hash(text_hash(text_hash(*hash, section), name), value);
  /* Materialize integer metadata as well as checking parser event order. */
  if (*value >= '0' && *value <= '9') {
    uint32_t number = 0;
    while (*value >= '0' && *value <= '9') number = number * 10u + (unsigned)(*value++ - '0');
    *hash = mix(*hash, number);
  }
  return 1;
}
#endif

uint32_t run(void) {
  uint32_t hash = 5381;
  for (unsigned repeat = 0; repeat < REPEATS; ++repeat) {
#if WORKLOAD == 0
    const char *cursor = (const char *)input;
    while (*cursor) {
      int length = 0;
      unsigned kind = 0;
      /* Only supported positive classes; no inverted class or regex alternation. */
      if (re_match("^[A-Za-z_][A-Za-z_0-9]*", cursor, &length) == 0) kind = 1;
      else if (re_match("^[0-9]+", cursor, &length) == 0) kind = 2;
      else if (re_match("^\\s+", cursor, &length) == 0) kind = 3;
      else { kind = 4; length = 1; }
      hash = mix(mix(hash, kind), (unsigned)length);
      for (int i = 0; i < length; ++i) hash = mix(hash, (unsigned char)cursor[i]);
      cursor += length;
    }
#elif WORKLOAD == 1
    int error = ini_parse_string((const char *)input, config_entry, &hash);
    if (error) return 0xbad00000u | (unsigned)error;
#else
    unsigned char removed[BOX_COUNT] = {0};
    for (unsigned rank = 0; rank < BOX_COUNT; ++rank) {
      unsigned best = BOX_COUNT;
      for (unsigned i = 0; i < BOX_COUNT; ++i)
        if (!removed[i] && (best == BOX_COUNT || boxes[i][4] > boxes[best][4])) best = i;
      if (best == BOX_COUNT) break;
      removed[best] = 1;
      hash = mix(mix(hash, best), (unsigned)boxes[best][4]);
      for (unsigned i = 0; i < BOX_COUNT; ++i) {
        if (removed[i] || boxes[i][5] != boxes[best][5]) continue;
        int x0 = boxes[i][0] > boxes[best][0] ? boxes[i][0] : boxes[best][0];
        int y0 = boxes[i][1] > boxes[best][1] ? boxes[i][1] : boxes[best][1];
        int x1 = boxes[i][2] < boxes[best][2] ? boxes[i][2] : boxes[best][2];
        int y1 = boxes[i][3] < boxes[best][3] ? boxes[i][3] : boxes[best][3];
        if (x1 <= x0 || y1 <= y0) continue;
        unsigned overlap = (unsigned)((x1-x0)*(y1-y0));
        unsigned a = (unsigned)((boxes[i][2]-boxes[i][0])*(boxes[i][3]-boxes[i][1]));
        unsigned b = (unsigned)((boxes[best][2]-boxes[best][0])*(boxes[best][3]-boxes[best][1]));
        if (overlap * 4u > a + b - overlap) removed[i] = 1;
      }
    }
#endif
  }
  return hash;
}
