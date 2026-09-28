/* Integer proxy: 256 signed-int8 dot products and scalar normalization.
 * This validates scalar M arithmetic, not a complete neural-network runtime. */
typedef signed char int8_t;
typedef unsigned int uint32_t;
static int8_t activations[64];
static int8_t weights[64];

int main(void) {
  for (unsigned i = 0; i < 64; ++i) {
    activations[i] = (int8_t)((i * 37 + 13) & 255);
    weights[i] = (int8_t)((i * 19 + 11) & 255);
  }
  uint32_t checksum = 0;
  for (unsigned round = 0; round < 256; ++round) {
    int accumulator = 0;
    for (unsigned i = 0; i < 64; ++i)
      accumulator += (int)activations[i] * (int)weights[(i + round) & 63];
    int normalized = accumulator / (int)((round & 15) + 1);
    checksum = ((checksum << 5) | (checksum >> 27)) ^ (uint32_t)normalized;
  }
  return checksum == EXPECTED_CHECKSUM ? 0 : 1;
}
